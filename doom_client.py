#!/usr/bin/env python3
import io
import math
import os
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from enum import Enum, auto

import psycopg2
import pygame

import doom_sql as sql
import dock
from audio import (load_sound_bank, play_sound_events, start_stage_music,
                   sync_sound_loops)
from dock import (StatsWorker, TIC_STAGES, dock_fonts, dock_width,
                  draw_fps_badge, draw_map_cull, draw_pipeline_graph,
                  draw_plan_replay, draw_sql_dock, draw_text_shadow,
                  draw_tic_rack)
import doom_config
from doom_config import (DB_DSN, DEFAULT_SKILL, JOIN_SLOT, MAP_ID,
                         MAX_TICS_PER_FRAME, MOUSE_SENSITIVITY, SCREEN_H,
                         SCREEN_W, WINDOW_SCALE, load_constants,
                         tune_replanning)
from render_worker import RenderWorker


# Doom matches cheats a keystroke at a time against a fixed list (st_stuff.c).
# Longest first so IDBEHOLDV wins over the IDBEHOLD prefix, and IDSPISPOPD is
# kept as Doom 1's spelling of IDCLIP.
AUTOMAP_PAN_SPEED = 900.0


# Only the keys the title/menu machine understands; anything else is ignored
# while a screen is up rather than falling through to the game bindings.
MENU_KEYS = {
    pygame.K_UP: "up", pygame.K_DOWN: "down",
    pygame.K_w: "up", pygame.K_s: "down",
    pygame.K_RETURN: "enter", pygame.K_KP_ENTER: "enter",
    pygame.K_SPACE: "enter", pygame.K_ESCAPE: "escape",
}


class Modal(Enum):
    NONE = auto()
    AUTOMAP = auto()
    # One list for both. Warping to a level is a cheat -- it is Doom's own
    # IDCLEV -- and now that the game has real level progression there is no
    # reason for it to have its own screen.


@dataclass(frozen=True)
class TicResult:
    snapshot: dict
    sound_events: object
    sound_loops: object
    sql_seconds: float
    audio_seconds: float


@dataclass
class GameSession:
    # The pose after the last tic, for the automap, the caption and the
    # renderer's warm-up. Frames between tics ask SQL for the blended camera
    # (client/camera_pose.sql); the client keeps no pose history of its own.
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0
    angle: float = 0.0
    physics_accumulator: float = 0.0
    pending_mouse_turn: float = 0.0
    pending_use: bool = False
    pending_weapon: object = None
    alive: bool = True
    last_sound_event_id: int = 0
    active_sound_loops: dict = field(default_factory=dict)
    music_stream: object = None
    # bit -> perf_counter() when that tic stage last executed, for the
    # rack's fade. A stage can fire for a single 28 ms tic.
    tic_stage_fired: dict = field(default_factory=dict)

    def stop_sound_loops(self):
        for channel, _sound_name in self.active_sound_loops.values():
            channel.stop()
        self.active_sound_loops.clear()

    def resync(self, cur, map_id, player_thing_id):
        """Adopt the pose already in SQL, without resetting the stage.

        Used after loading: the world in the tables IS the saved world, so
        restart()'s reset_stage + spawn_stage would discard exactly what was
        just restored.
        """
        row = sql.player_pose(cur, map_id, player_thing_id)
        if row is None:
            return
        self.x, self.y, self.angle, self.z, self.alive = row
        self.physics_accumulator = 0.0
        self.pending_mouse_turn = 0.0
        self.pending_use = False
        self.pending_weapon = None
        self.last_sound_event_id = 0

    def restart(self, cur, stage, skill, carry_from=None):
        """Enter the level (SQL's G_DoLoadLevel) and reset transient input.

        carry_from is the (map, player) just finished, whose weapons, ammo,
        armour and health come with the player -- Doom's G_WorldDone.
        """
        map_id = stage["map_id"]
        player_id = stage["player_thing_id"]
        self.stop_sound_loops()
        self.x, self.y, self.angle, self.z = sql.enter_level(
            cur, map_id, player_id, skill, carry_from)
        self.music_stream = start_stage_music(cur, map_id)
        self.physics_accumulator = 0.0
        self.pending_mouse_turn = 0.0
        self.pending_use = False
        self.pending_weapon = None
        self.alive = True
        self.last_sound_event_id = 0


def mp_client_tic(cur, map_id, player_thing_id, command, after_sound_id):
    """One client-side tic of a deathmatch: the server runs the world.

    The command goes into mp_inputs for the server's next tic; the snapshot
    and sounds come back from whatever the server has done so far.
    """
    started = time.perf_counter()
    sql.mp_push_input(cur, map_id, player_thing_id, command)
    audio_started = time.perf_counter()
    sound_events, sound_loops = sql.fetch_sound_events(
        cur, map_id, player_thing_id, after_sound_id,
    )
    audio_seconds = time.perf_counter() - audio_started
    snapshot = sql.finish_game_tic(cur, map_id, player_thing_id)
    return TicResult(
        snapshot, sound_events, sound_loops,
        time.perf_counter() - started, audio_seconds,
    )


def wait_for_match(cur, map_id, slot):
    """Block until the referee has opened a match this role is bound to; return
    the player Thing that is us. The slot is the role's, not ours to choose."""
    announced = False
    while True:
        player = sql.api_join(cur)
        if player is not None:
            return player
        if not announced:
            print(f"[join] waiting for a deathmatch server on map {map_id}...")
            announced = True
        time.sleep(0.5)


def run_game_tic(cur, map_id, player_thing_id, command, after_sound_id):
    """Run one prepared SQL-owned tic and project its snapshot/audio rows."""
    started = time.perf_counter()
    sound_due = sql.execute_game_tic(cur, map_id, player_thing_id, command)

    sound_events = sound_loops = None
    audio_seconds = 0.0
    if sound_due:
        audio_started = time.perf_counter()
        sound_events, sound_loops = sql.fetch_sound_events(
            cur, map_id, player_thing_id, after_sound_id,
        )
        audio_seconds = time.perf_counter() - audio_started
    snapshot = sql.finish_game_tic(cur, map_id, player_thing_id)
    return TicResult(
        snapshot, sound_events, sound_loops,
        time.perf_counter() - started, audio_seconds,
    )


def scaled_size(scale):
    return SCREEN_W * scale, SCREEN_H * scale


def best_window_scale(max_scale=16, width_fraction=0.96,
                      height_fraction=0.92):
    """Largest integer scale whose whole window still fits the desktop.

    The window is the game plus the dock, so it is wider than Doom's 16:10 --
    at 320x200 per unit plus a 96-wide dock that is 416x200 per unit, and
    picking the scale from height alone pushes the dock off the side of the
    screen. The fractions leave room for the title bar and a taskbar.
    """
    try:
        desktop_w, desktop_h = pygame.display.get_desktop_sizes()[0]
    except Exception:
        info = pygame.display.Info()
        desktop_w, desktop_h = info.current_w, info.current_h
    if desktop_w < 640 or desktop_h < 480:
        # Headless or a driver that will not say; pick something reasonable.
        return 4
    budget_w = desktop_w * width_fraction
    budget_h = desktop_h * height_fraction
    best = 1
    for scale in range(1, max_scale + 1):
        width, height = window_size(scale)
        if width <= budget_w and height <= budget_h:
            best = scale
    return best


def window_size(scale):
    game_width, game_height = scaled_size(scale)
    return game_width + dock_width(scale), game_height


def strip_height(scale):
    """Desktop height left over below the viewport, for the BSP band.

    The window is wider than it is tall once the dock is attached, so the scale
    is limited by width and there is usually a band of screen going unused
    underneath. It costs nothing to claim it.
    """
    try:
        desktop_h = pygame.display.get_desktop_sizes()[0][1]
    except Exception:
        desktop_h = pygame.display.Info().current_h
    if desktop_h < 480:
        return 0
    spare = int(desktop_h * 0.92) - SCREEN_H * scale
    if spare < 24 * scale:
        return 0
    return min(spare, round(SCREEN_H * scale * 0.45))


def open_window(scale, bare=False):
    """Open the display and return (display, game view, BSP band rect).

    The game view is a subsurface covering only the game's part of the window,
    so every drawing routine keeps measuring the area it actually draws into
    and neither the docked panel nor the band can be drawn over. The dock runs
    the full window height; the band runs the width of the game beneath it.
    """
    game_width, game_height = scaled_size(scale)
    # Performance mode drops the dock and the band entirely rather than
    # leaving them blank: the window becomes exactly the game, and the two
    # drawing paths switch themselves off -- draw_sql_dock returns early on a
    # zero-width dock, and the band is guarded on band_rect being None.
    band = 0 if bare else strip_height(scale)
    width = game_width if bare else window_size(scale)[0]
    display = pygame.display.set_mode((width, game_height + band))
    view = display.subsurface((0, 0, game_width, game_height))
    band_rect = (pygame.Rect(0, game_height, game_width, band)
                 if band else None)
    return display, view, band_rect


def resize_window(scale, delta, base_surface, bare=False):
    scale = max(1, scale + delta)
    display, window, band_rect = open_window(scale, bare)
    hud_font = pygame.font.Font(
        None, max(18, min(36, window.get_height() // 55))
    )
    scaled_surface = None
    if base_surface is not None:
        scaled_surface = pygame.transform.scale(
            base_surface, scaled_size(scale)
        )
    return scale, display, window, band_rect, hud_font, scaled_surface


def set_mouse_capture(captured):
    pygame.event.set_grab(captured)
    pygame.mouse.set_visible(not captured)
    pygame.mouse.get_rel()
    return captured


# The title/menu/intermission frames come back from SQL as the same 320x200
# RGB buffer the renderer returns, so they blit exactly like a game frame.
# Compositing one costs 6-7 ms, too slow to redo every display frame, so it is
# cached on the values it depends on -- the same repaint-on-change rule the SQL
# dock uses. The key's last element is treated as a sub-state of the same
# screen and both of its values are kept: the menu skull blinks forever on
# Doom's 8-tic step, so after one blink cycle a menu that is merely blinking
# costs nothing at all, and only a real change (cursor, episode, skill) pays
# for a recomposite.
_SCREEN_CACHE = {"base": None, "frames": {}, "scaled": {}, "size": None}


def invalidate_sql_screen():
    """Drop the cached screen, for when the world behind it has changed."""
    _SCREEN_CACHE["base"] = None
    _SCREEN_CACHE["frames"] = {}
    _SCREEN_CACHE["scaled"] = {}


def draw_sql_screen(window, cur, key, skull_step, automap=None):
    """Blit the SQL-composited screen. Returns False if it could not render."""
    base, phase = key[:-1], key[-1]
    if base != _SCREEN_CACHE["base"]:
        invalidate_sql_screen()
        _SCREEN_CACHE["base"] = base
    size = window.get_size()
    if _SCREEN_CACHE["size"] != size:
        _SCREEN_CACHE["scaled"] = {}
        _SCREEN_CACHE["size"] = size
    scaled = _SCREEN_CACHE["scaled"].get(phase)
    if scaled is None:
        frame = _SCREEN_CACHE["frames"].get(phase)
        if frame is None:
            try:
                raw = (sql.render_automap(cur, *automap) if automap
                       else sql.render_screen(cur, skull_step * 8))
            except Exception:
                cur.connection.rollback()
                return False
            if raw is None or len(raw) != 320 * 200 * 3:
                return False
            frame = pygame.image.frombuffer(raw, (320, 200), "RGB")
            _SCREEN_CACHE["frames"][phase] = frame
        scaled = pygame.transform.scale(frame, size)
        _SCREEN_CACHE["scaled"][phase] = scaled
    window.blit(scaled, (0, 0))
    return True


# D_DoAdvanceDemo's page lengths, in tics. Vanilla holds TITLEPIC for 170 and
# a text page for 200 before moving on.
def snapshot_health(cur, map_id, player_thing_id):
    """The player's health right now, for the exit log line."""
    cur.execute(
        "SELECT health, sector_id FROM player_state"
        " WHERE map_id=%s AND player_thing_id=%s",
        (map_id, player_thing_id),
    )
    row = cur.fetchone()
    return "?" if row is None else f"{row[0]} in sector {row[1]}"


def main():
    # A joining client is an unprivileged player role: every statement goes
    # through the server's api_* views and functions.
    sql.API_MODE = bool(JOIN_SLOT)
    conn = psycopg2.connect(DB_DSN)
    conn.autocommit = True
    cur = conn.cursor()
    tune_replanning(cur)
    load_constants(cur)
    stages = sql.load_stages(cur)
    if not stages:
        raise RuntimeError("no maps with a type-1 player start are loaded")
    active_stage_index = next(
        (i for i, stage in enumerate(stages) if stage["map_id"] == MAP_ID), 0
    )
    active_stage = stages[active_stage_index]
    map_id = active_stage["map_id"]
    player_thing_id = active_stage["player_thing_id"]

    sql.prepare_client(cur)
    if JOIN_SLOT:
        player_thing_id = wait_for_match(cur, map_id, JOIN_SLOT)
        active_stage = dict(active_stage, player_thing_id=player_thing_id,
                            label=f"{active_stage['label']} deathmatch")

    pygame.mixer.pre_init(frequency=44100, size=-16, channels=2, buffer=512)
    pygame.init()
    if pygame.mixer.get_init() is not None:
        pygame.mixer.set_num_channels(24)
        pygame.mixer.set_reserved(8)
    sound_bank = load_sound_bank(cur)
    window_scale = (max(1, int(float(WINDOW_SCALE))) if WINDOW_SCALE
                    else best_window_scale())
    # A player role cannot read the renderer's pipeline or plan, so a joining
    # client opens without the dock, the way F6 does.
    display, window, band_rect = open_window(window_scale, bare=bool(JOIN_SLOT))
    pygame.display.set_caption(
        f"SQL Doom — {active_stage['label']}"
        + (f" — Player {JOIN_SLOT}" if JOIN_SLOT else "")
        + " — LMB/Ctrl=fire, Space=use, Tab=map, F6=performance mode"
    )
    font = pygame.font.Font(None, 24)
    hud_font = pygame.font.Font(
        None, max(18, min(36, window.get_height() // 55))
    )
    dock_font_set = dock_fonts(window_scale)
    clock = pygame.time.Clock()
    mouse_captured = set_mouse_capture(True)
    modal = Modal.NONE
    current_skill = DEFAULT_SKILL
    session = GameSession()
    if JOIN_SLOT:
        # The server owns the world: adopt it rather than resetting it, and go
        # straight into the level -- no title screen, no menus.
        session.resync(cur, map_id, player_thing_id)
        session.music_stream = start_stage_music(cur, map_id)
        menu_screen = None
    else:
        session.restart(cur, active_stage, current_skill)
        # Doom opens on the title screen, not in a level. The stage above is
        # still prepared so the world exists behind the menu and starting a
        # game is just a stage change; menu_screen being non-None is what
        # suppresses gameplay.
        sql.set_screen(cur, "title")
        menu_screen = "title"
    # Which line the skull sits on, and the episode/skill the menu is showing,
    # are as much a part of the picture as which screen it is. Keeping only
    # the screen name meant a cursor move did not invalidate the cached
    # composite, so the skull did not visibly move until the blink flipped --
    # up to 229 ms of dead time on every keypress.
    menu_state = ({"screen": "game", "cursor": 0, "episode": 1, "skill": 2}
                  if JOIN_SLOT else sql.screen_state(cur))
    tic_failures = 0
    # Demo recording/playback and D_DoAdvanceDemo's attract loop are SQL's
    # (41_flow.sql). The client mirrors two facts from every snapshot -- which
    # screen is up and whether a demo is driving the input -- and steps the
    # attract loop's 35 Hz clock while a page is showing.
    demo_active = False
    demo_recording_name = None
    attract_on = not JOIN_SLOT
    attract_accumulator = 0.0
    if attract_on:
        sql.attract_start(cur)

    renderer = RenderWorker(map_id, player_thing_id, current_skill)
    # Static for the level, so it is read once here and on a stage change.
    map_geometry = sql.fetch_map_geometry(cur, map_id)
    stats_worker = StatsWorker(map_id, player_thing_id, current_skill)

    cached_frame_id = 0
    cached_base_surface = None
    cached_scaled_surface = None
    sql_fps_history = deque(maxlen=512)
    sql_frame_completions = deque(maxlen=512)
    sql_next_rate_sample = time.perf_counter() + 0.25
    gameplay_sql_history = deque(maxlen=2048)
    # The first tic after a (re)start is not a tic -- it is CedarDB compiling
    # the prepared pipeline, tens to hundreds of times the cost of a real one.
    # Charting it pins the y axis to a number nothing else comes near and
    # flattens every honest sample onto the axis, so it is dropped.
    tic_warmup_pending = True
    # Performance mode (F6): stop paying for the diagnostics. The render-stats
    # and plan sampling each run the whole render pipeline on their own
    # connection, so they cost real server time; the frame rate and the tic
    # timing are read off work the game already does and stay live.
    perf_mode = bool(JOIN_SLOT)
    # F7. Off by default: it is a deviation from what the renderer produced,
    # and the frame the SQL side hands over is the one to judge it by.
    # IDDT is not sent to SQL: it only changes what the automap query draws.
    # Doom cycles one counter rather than toggling a flag -- 0 off, 1 every
    # line, 2 every line plus a triangle on every thing.
    cheat_buffer = ""
    deferred_exit_secret = None
    # The tally now lives in SQL (doom_intermission_*). The client keeps only
    # what it needs to drive it: whether it is up, its own 35 Hz accumulator,
    # where it says to go next, and the figures it last reported -- which are
    # the repaint key for the composited screen.
    inter_active = False
    inter_accumulator = 0.0
    inter_next_map = None
    inter_figures = (0, 0, 0, 0, 0, 0)
    # End-of-episode finale (f_finale.c), composited in SQL like the tally.
    # Its own 35 Hz accumulator, and the (stage, count) SQL keeps, which is
    # what says whether the page has actually changed.
    finale_active = False
    finale_accumulator = 0.0
    finale_key = (0, 0)

    running = True
    while running:
        dt = min(clock.tick(120) / 1000.0, 0.1)
        game_sql_seconds = 0.0
        game_audio_seconds = 0.0
        mouse_dx = 0
        stage_to_activate = None
        # Set only when a completed level hands over to the next one, so
        # picking a stage from the menu or respawning still pistol-starts.
        carry_from = None
        respawn_requested = False

        if deferred_exit_secret is not None and not inter_active:
            # G_DoCompleted, in SQL: the level's totals frozen, the tally
            # computed and the next level routed. Compile and warm the
            # renderer for it while the tally is on screen, so the one-off
            # replan lands here instead of on the new level's first frame.
            inter_next_map = sql.level_exit(
                cur, map_id, player_thing_id, deferred_exit_secret,
            )
            inter_active = True
            inter_accumulator = 0.0
            inter_figures = (0, 0, 0, 0, 0, 0)
            next_stage = next(
                (st for st in stages if st["map_id"] == inter_next_map), None)
            if next_stage is not None:
                renderer.prefetch(next_stage["map_id"],
                                  next_stage["player_thing_id"], current_skill)
            invalidate_sql_screen()
            deferred_exit_secret = None

        # The tally runs on its own 35 Hz clock -- gameplay's accumulator is
        # gated on controls_enabled, which is false while a screen is up.
        if inter_active:
            inter_accumulator += dt
            while inter_accumulator >= doom_config.TIC_SECONDS:
                inter_accumulator -= doom_config.TIC_SECONDS
                inter_status, inter_figures = sql.intermission_tic(cur)
                if inter_status == "done":
                    # G_WorldDone, in SQL: the finale when the episode is
                    # over, else the level that follows.
                    inter_active = False
                    outcome = sql.after_intermission(cur, map_id)
                    if outcome == "finale":
                        finale_active = True
                        finale_accumulator = 0.0
                        finale_key = sql.finale_phase(cur)
                        invalidate_sql_screen()
                        break
                    next_map = int(outcome.split(":", 1)[1])
                    stage_to_activate = next(
                        (i for i, st in enumerate(stages)
                         if st["map_id"] == next_map),
                        (active_stage_index + 1) % len(stages),
                    )
                    carry_from = (map_id, player_thing_id)
                    break

            mouse_captured = set_mouse_capture(False)
            session.stop_sound_loops()

        if finale_active:
            finale_accumulator += dt
            ticked = False
            while finale_accumulator >= doom_config.TIC_SECONDS:
                finale_accumulator -= doom_config.TIC_SECONDS
                ticked = True
                if sql.finale_tic(cur) == "done":
                    finale_active = False
                    break
            if ticked and finale_active:
                finale_key = sql.finale_phase(cur)
            mouse_captured = set_mouse_capture(False)
            session.stop_sound_loops()

        # Handle events. A render is requested every iteration, so a failed
        # frame retries by itself on the next one; R only forces a redraw at
        # the exact current pose.
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN:
                if JOIN_SLOT and event.key in (
                        pygame.K_ESCAPE, pygame.K_F5, pygame.K_F8,
                        pygame.K_F9, pygame.K_F10):
                    # Menus, saves and demos are single-player; the server
                    # owns this world. Close the window to leave.
                    continue
                if attract_on:
                    # G_Responder: a key during the attract loop ends it and
                    # hands control back. The demo stops where it is.
                    attract_on = False
                    sql.attract_stop(cur)
                    if demo_active:
                        demo_active = False
                        menu_screen = "title"
                        menu_state = sql.screen_state(cur)
                        invalidate_sql_screen()
                        continue
                if (menu_screen is None and not inter_active
                        and not finale_active and not JOIN_SLOT
                        and (pygame.K_a <= event.key <= pygame.K_z
                             or pygame.K_0 <= event.key <= pygame.K_9)):
                    action = sql.cheat_key(
                        cur, map_id, player_thing_id, chr(event.key))
                    if action.startswith("warp:"):
                        target = action[5:]
                        chosen = next(
                            (i for i, st in enumerate(stages)
                             if st["label"].startswith(target)), None)
                        if chosen is None:
                            print(f"[cheat] {target} is not loaded")
                        else:
                            print(f"[cheat] warping to {target}")
                            stage_to_activate = chosen
                    elif action.startswith("music:"):
                        target = action[6:]
                        wanted = next(
                            (st for st in stages
                             if st["label"].startswith(target)), None)
                        if wanted is None:
                            print(f"[cheat] no music for {target}")
                        else:
                            session.music_stream = start_stage_music(
                                cur, wanted["map_id"])
                            print("[cheat] Music Change")
                    elif action == "iddt":
                        # Doom's IDDT only does anything with the map open.
                        if modal is Modal.AUTOMAP:
                            sql.automap_toggle(cur, map_id, player_thing_id, "cheat")
                            invalidate_sql_screen()
                    elif action.startswith("msg:"):
                        print(f"[cheat] {action[4:]}")
                if finale_active:
                    # Not vanilla: F_Responder ignores keys here. See
                    # doom_finale_advance.
                    if sql.finale_advance(cur) == "done":
                        finale_active = False
                        menu_screen = "title"
                        menu_state = sql.screen_state(cur)
                    else:
                        finale_key = sql.finale_phase(cur)
                    invalidate_sql_screen()
                    continue
                if menu_screen is not None:
                    key_name = MENU_KEYS.get(event.key)
                    if key_name is not None:
                        action, menu = sql.menu_input(cur, key_name)
                        menu_state = menu
                        was_open = menu_screen is not None
                        menu_screen = (None if menu["screen"] == "game"
                                       else menu["screen"])
                        if was_open and menu_screen is None:
                            # Escape opens the menu with the mouse released,
                            # so closing it again has to take the mouse back.
                            # Without this, mouse-look and mouse-fire stayed
                            # dead after Esc-Esc even though the keyboard
                            # still worked.
                            mouse_captured = set_mouse_capture(True)
                            session.pending_mouse_turn = 0.0
                            pygame.mouse.get_rel()
                        if action == "quit":
                            running = False
                        elif action.startswith("load:"):
                            slot = int(action.split(":", 1)[1])
                            restored = sql.load_game(cur, slot)
                            loaded = (None if restored is None
                                      else restored["map_id"])
                            if restored is not None:
                                # Adopt the saved world's skill, or the client
                                # would filter Things by a different one.
                                current_skill = restored["skill"]
                            if loaded is None:
                                # Slot vanished between menu and keypress.
                                sql.set_screen(cur, "load")
                                menu_screen = "load"
                                menu_state = sql.screen_state(cur)
                            else:
                                chosen = next(
                                    (i for i, st in enumerate(stages)
                                     if st["map_id"] == loaded), None)
                                if chosen is not None:
                                    active_stage_index = chosen
                                    active_stage = stages[chosen]
                                    map_id = active_stage["map_id"]
                                    player_thing_id = \
                                        active_stage["player_thing_id"]
                                    map_geometry = sql.fetch_map_geometry(
                                        cur, map_id)
                                    dock.invalidate_geometry()
                                # The world is already the saved one, so the
                                # session is resynced from it WITHOUT the
                                # reset+spawn that a stage change does -- that
                                # would throw the loaded state away.
                                session.resync(cur, map_id, player_thing_id)
                                cached_base_surface = None
                                cached_scaled_surface = None
                                mouse_captured = set_mouse_capture(True)
                                cached_frame_id = renderer.request(
                                    (session.x, session.y,
                                     session.z, session.angle),
                                    map_id, player_thing_id, current_skill,
                                    invalidate=True,
                                )
                        elif action.startswith("save:"):
                            slot = int(action.split(":", 1)[1])
                            sql.save_game(
                                cur, slot, map_id, player_thing_id,
                                current_skill, active_stage["label"].split()[0])
                            # The slot list is part of what the Load and Save
                            # screens draw, so a cached composite of either is
                            # stale the moment a slot is written.
                            invalidate_sql_screen()
                            mouse_captured = set_mouse_capture(True)
                        elif action == "start":
                            target = f"E{menu['episode']}M1"
                            chosen = next(
                                (i for i, st in enumerate(stages)
                                 if st["label"].startswith(target)), None)
                            current_skill = menu["skill"]
                            if chosen is not None:
                                stage_to_activate = chosen
                            else:
                                stage_to_activate = active_stage_index
                    continue
                if inter_active:
                    if event.key in (pygame.K_RETURN, pygame.K_KP_ENTER,
                                     pygame.K_SPACE, pygame.K_ESCAPE):
                        # One key does both jobs, as in Doom: it snaps the
                        # tally to its totals, and once everything is shown it
                        # leaves for the next level.
                        sql.intermission_accelerate(cur)
                    continue
                if event.key == pygame.K_F6:
                    perf_mode = not perf_mode
                    # A pose of None is how StatsWorker is told to stop
                    # sampling, so the thread idles instead of re-counting the
                    # last pose forever. Turning the mode off re-arms it on the
                    # next frame, from the pose the renderer is handed.
                    if perf_mode:
                        stats_worker.request(None)
                    # Reopen at the mode's own size: performance mode is the
                    # game and nothing else, so the window loses the dock's
                    # column and the band's strip rather than showing them
                    # empty.
                    (window_scale, display, window, band_rect,
                     hud_font, cached_scaled_surface) = resize_window(
                        window_scale, 0, cached_base_surface, perf_mode,
                    )
                    dock_font_set = dock_fonts(window_scale)
                    dock.reset_fps_badge()
                    print("performance mode "
                          + ("on: dock, band and SQL sampling off"
                             if perf_mode else "off"))
                    continue
                if not session.alive:
                    # P_DeathThink restarts the level on BT_USE and nothing
                    # else, so Space alone -- the use key -- does it here too.
                    # In a deathmatch the press goes to the server instead.
                    if event.key == pygame.K_SPACE:
                        respawn_requested = not JOIN_SLOT
                        continue
                    # Doom keeps the automap and the menu working while you
                    # lie there; only the gameplay keys stop. Swallowing every
                    # key here made a death look like the game had frozen.
                    if event.key not in (pygame.K_TAB, pygame.K_ESCAPE):
                        continue
                if modal is Modal.AUTOMAP:
                    if event.key in (pygame.K_ESCAPE, pygame.K_TAB):
                        modal = Modal.NONE
                        mouse_captured = set_mouse_capture(True)
                    elif event.key == pygame.K_f:
                        sql.automap_toggle(cur, map_id, player_thing_id, "follow")
                        invalidate_sql_screen()
                    elif event.key == pygame.K_g:
                        sql.automap_toggle(cur, map_id, player_thing_id, "grid")
                        invalidate_sql_screen()
                    elif event.key == pygame.K_HOME:
                        sql.automap_fit(cur, map_id, player_thing_id)
                        invalidate_sql_screen()
                    elif event.key in (pygame.K_MINUS, pygame.K_KP_MINUS,
                                       pygame.K_LEFTBRACKET):
                        sql.automap_zoom(cur, map_id, player_thing_id, 1 / 1.25)
                        invalidate_sql_screen()
                    elif event.key in (pygame.K_EQUALS, pygame.K_KP_PLUS,
                                       pygame.K_RIGHTBRACKET):
                        sql.automap_zoom(cur, map_id, player_thing_id, 1.25)
                        invalidate_sql_screen()
                    continue

                if event.key == pygame.K_ESCAPE:
                    # Doom's Escape opens the menu; quitting is the menu's own
                    # Quit Game line. This is also the only route to Save/Load.
                    sql.set_screen(cur, "main")
                    menu_screen = "main"
                    menu_state = sql.screen_state(cur)
                    invalidate_sql_screen()
                    mouse_captured = set_mouse_capture(False)
                elif event.key == pygame.K_TAB:
                    modal = Modal.AUTOMAP
                    mouse_captured = set_mouse_capture(False)
                elif event.key == pygame.K_BACKQUOTE:
                    mouse_captured = set_mouse_capture(not mouse_captured)
                elif event.key == pygame.K_F5:
                    # Print the exact camera the renderer is being handed, so
                    # a visual glitch can be reproduced away from the client.
                    print(
                        f"[pose] map={map_id} player={player_thing_id} "
                        f"skill={current_skill}\n"
                        f"    x={session.x:.4f} y={session.y:.4f} "
                        f"z={session.z:.4f} angle={session.angle:.4f}",
                        file=sys.stderr, flush=True,
                    )
                elif event.key == pygame.K_r:
                    renderer.request(
                        (session.x, session.y, session.z, session.angle),
                    )
                elif event.key == pygame.K_F9:
                    if demo_recording_name is not None:
                        print(f"[demo] recorded '{demo_recording_name}' on "
                              f"{active_stage['label']}")
                        sql.demo_stop(cur)
                        demo_recording_name = None
                    else:
                        demo_recording_name = (
                            f"{active_stage['label'].lower()}-demo")
                        sql.demo_begin(cur, demo_recording_name, map_id,
                                       player_thing_id, current_skill)
                        stage_to_activate = active_stage_index
                        print(f"[demo] recording '{demo_recording_name}' from "
                              f"the start of {active_stage['label']} -- F9 "
                              "again to stop")
                elif event.key == pygame.K_F10:
                    if attract_on:
                        attract_on = False
                        sql.attract_stop(cur)
                    if demo_active:
                        print("[demo] playback stopped")
                        sql.demo_stop(cur)
                        demo_active = False
                    else:
                        demo_recording_name = None
                        header = sql.demo_play(
                            cur, f"{active_stage['label'].lower()}-demo")
                        if header is None:
                            print("[demo] nothing recorded for "
                                  f"{active_stage['label']} yet -- F9 records")
                        else:
                            demo_active = True
                            current_skill = header["skill"]
                            stage_to_activate = active_stage_index
                            print(f"[demo] playing back {header['tic_count']} "
                                  f"tics of {active_stage['label']}")
                elif event.key == pygame.K_SPACE:
                    session.pending_use = True
                elif pygame.K_1 <= event.key <= pygame.K_7:
                    session.pending_weapon = sql.select_weapon_slot(
                        cur,map_id,player_thing_id,event.key-pygame.K_0
                    )
                elif event.key in (pygame.K_MINUS, pygame.K_KP_MINUS,
                                    pygame.K_LEFTBRACKET):
                    (window_scale, display, window, band_rect,
                     hud_font, cached_scaled_surface) = resize_window(
                        window_scale, -1, cached_base_surface, perf_mode,
                    )
                    dock_font_set = dock_fonts(window_scale)
                elif event.key in (pygame.K_EQUALS, pygame.K_KP_PLUS,
                                    pygame.K_RIGHTBRACKET):
                    (window_scale, display, window, band_rect,
                     hud_font, cached_scaled_surface) = resize_window(
                        window_scale, 1, cached_base_surface, perf_mode,
                    )
                    dock_font_set = dock_fonts(window_scale)
            elif event.type == pygame.MOUSEWHEEL and modal is Modal.AUTOMAP:
                if event.y:
                    sql.automap_zoom(cur, map_id, player_thing_id,
                                     1.15 ** event.y)
                    invalidate_sql_screen()
            elif (event.type == pygame.MOUSEWHEEL and event.y
                  and modal is Modal.NONE and menu_screen is None
                  and not inter_active and not finale_active):
                # Wheel up is the next weapon, wheel down the previous, over
                # the ones actually owned. SQL picks it, the same way the
                # number keys do; the client only says which direction.
                picked = sql.cycle_weapon(
                    cur, map_id, player_thing_id,
                    1 if event.y > 0 else -1,
                )
                if picked is not None:
                    session.pending_weapon = picked
            elif (event.type == pygame.MOUSEMOTION and mouse_captured
                  and modal is Modal.NONE):
                mouse_dx += event.rel[0]
            elif event.type == pygame.MOUSEBUTTONDOWN:
                if inter_active and event.button == 1:
                    sql.intermission_accelerate(cur)
                elif modal is Modal.AUTOMAP and event.button in (4, 5):
                    sql.automap_zoom(cur, map_id, player_thing_id,
                                     1.15 if event.button == 4 else 1.0 / 1.15)
                    invalidate_sql_screen()
                elif not mouse_captured and modal is Modal.NONE:
                    mouse_captured = set_mouse_capture(True)
            elif event.type == pygame.WINDOWFOCUSLOST and mouse_captured:
                mouse_captured = set_mouse_capture(False)

        # D_PageTicker, in SQL: count the current attract page down and move
        # on. The loop only runs while nobody is playing; any key ends it.
        if attract_on and not demo_active and menu_screen is not None:
            attract_accumulator += dt
            while attract_accumulator >= doom_config.TIC_SECONDS:
                attract_accumulator -= doom_config.TIC_SECONDS
                outcome = sql.attract_tic(cur)
                if outcome == "none":
                    continue
                if outcome == "page":
                    menu_state = sql.screen_state(cur)
                    menu_screen = menu_state["screen"]
                    invalidate_sql_screen()
                    continue
                header = sql.demo_header(cur, int(outcome.split(":", 1)[1]))
                chosen = next(
                    (i for i, st in enumerate(stages)
                     if header is not None and st["map_id"] == header["map_id"]),
                    None)
                if chosen is None:
                    # A demo whose map is not loaded: drop it, the loop moves
                    # on to its next page on the next step.
                    sql.demo_stop(cur)
                    continue
                print(f"[attract] playing '{header['name']}' on "
                      f"{stages[chosen]['label']}")
                current_skill = header["skill"]
                stage_to_activate = chosen
                demo_active = True
                menu_screen = None
                break

        restarting = stage_to_activate is not None or respawn_requested
        if restarting:
            stage_changed = stage_to_activate is not None
            if stage_changed:
                inter_active = False
                inter_next_map = None
                active_stage_index = stage_to_activate
                active_stage = stages[active_stage_index]
                map_id = active_stage["map_id"]
                player_thing_id = active_stage["player_thing_id"]

            session.restart(cur, active_stage, current_skill, carry_from)
            carry_from = None
            if stage_changed:
                map_geometry = sql.fetch_map_geometry(cur, map_id)
                dock.invalidate_geometry()
            cached_base_surface = None
            cached_scaled_surface = None
            mouse_captured = set_mouse_capture(True)
            # Ask for the new world's statement before the first request for
            # it, so the compile overlaps the stage reset on this thread. On a
            # normal level change the intermission already did this and the
            # worker skips it.
            renderer.prefetch(map_id, player_thing_id, current_skill,
                              (session.x, session.y, session.z, session.angle))
            cached_frame_id = renderer.request(
                (session.x, session.y, session.z, session.angle),
                map_id, player_thing_id, current_skill, invalidate=True,
            )
            if not perf_mode:
                stats_worker.request(
                    (session.x, session.y, session.z, session.angle),
                    map_id, player_thing_id, current_skill,
                )
            sql_fps_history.clear()
            sql_frame_completions.clear()
            gameplay_sql_history.clear()
            tic_warmup_pending = True
            sql_next_rate_sample = time.perf_counter() + 0.25
            if stage_changed:
                pygame.display.set_caption(
                    f"SQL Doom — {active_stage['label']} — LMB/Ctrl=fire, "
                    "Space=use, Tab=map, F6=perf, F9=record, F10=play"
                )

        keys = pygame.key.get_pressed()

        if modal is Modal.AUTOMAP:
            pan_x = ((1 if keys[pygame.K_d] or keys[pygame.K_RIGHT] else 0)
                     - (1 if keys[pygame.K_a] or keys[pygame.K_LEFT] else 0))
            pan_y = ((1 if keys[pygame.K_w] or keys[pygame.K_UP] else 0)
                     - (1 if keys[pygame.K_s] or keys[pygame.K_DOWN] else 0))
            if pan_x or pan_y:
                length = math.hypot(pan_x, pan_y)
                pan_distance = AUTOMAP_PAN_SPEED * dt
                sql.automap_pan(cur, map_id, player_thing_id,
                                pan_x / length * pan_distance,
                                pan_y / length * pan_distance)
                invalidate_sql_screen()

        # Sample input at display speed. Gameplay consumes the latest state on
        # fixed 35 Hz tics, independently of SQL render completion.
        # Two different questions. Doom keeps ticking the world while you lie
        # there dead -- monsters still move, lifts still run, and the view
        # sinks to the floor -- so the clock is not gated on being alive. Only
        # the commands are: a corpse issues none.
        world_running = (
            modal is Modal.NONE and not inter_active and menu_screen is None
            and not finale_active
        )
        controls_enabled = world_running and session.alive
        run = controls_enabled and (keys[pygame.K_LSHIFT] or keys[pygame.K_RSHIFT])
        attack_held = controls_enabled and (
            keys[pygame.K_LCTRL] or keys[pygame.K_RCTRL]
            or (mouse_captured and pygame.mouse.get_pressed(num_buttons=3)[0])
        )
        if JOIN_SLOT and world_running and not session.alive:
            # P_DeathThink: fire or use while dead is the request to respawn.
            # The server decides when; the press just has to reach it.
            attack_held = bool(
                keys[pygame.K_LCTRL] or keys[pygame.K_RCTRL]
                or keys[pygame.K_SPACE]
                or (mouse_captured
                    and pygame.mouse.get_pressed(num_buttons=3)[0])
            )

        # Horizontal turning only: vertical mouse motion is intentionally ignored,
        # matching classic Doom's level view.
        turn_input = controls_enabled * (
            (1.0 if (keys[pygame.K_e] or keys[pygame.K_RIGHT]) else 0.0)
            - (1.0 if (keys[pygame.K_q] or keys[pygame.K_LEFT]) else 0.0)
        )
        if controls_enabled:
            session.pending_mouse_turn += mouse_dx * MOUSE_SENSITIVITY
        else:
            session.pending_mouse_turn = 0.0

        # Intent
        move_fwd = controls_enabled * (
            (1.0 if (keys[pygame.K_w] or keys[pygame.K_UP]) else 0.0)
            - (1.0 if (keys[pygame.K_s] or keys[pygame.K_DOWN]) else 0.0)
        )
        move_strafe = controls_enabled * (
            (1.0 if keys[pygame.K_d] else 0.0)
            - (1.0 if keys[pygame.K_a] else 0.0)
        )

        session.physics_accumulator += dt if world_running else 0.0
        physics_tics = 0
        while (session.physics_accumulator >= doom_config.TIC_SECONDS
               and physics_tics < MAX_TICS_PER_FRAME):
            session.physics_accumulator -= doom_config.TIC_SECONDS
            physics_tics += 1

            tic_mouse_turn = session.pending_mouse_turn
            session.pending_mouse_turn = 0.0
            tic_turn = turn_input * doom_config.TURN_DEGREES_PER_TIC + tic_mouse_turn

            command = (
                current_skill, move_fwd, move_strafe, run, tic_turn,
                attack_held, session.pending_weapon, session.pending_use,
            )
            session.pending_weapon = None
            session.pending_use = False
            try:
                tic_result = (mp_client_tic if JOIN_SLOT else run_game_tic)(
                    cur, map_id, player_thing_id, command,
                    session.last_sound_event_id,
                )
                tic_failures = 0
            except psycopg2.Error as exc:
                # One tic failing is not a reason to end the session. Cedar can
                # raise a serialization failure or a constraint-validation
                # error on a tic if anything else writes the same map's tables
                # at the same moment -- another client, or a save/load running
                # elsewhere -- and losing 1/35th of a second beats losing the
                # game. A persistent fault is different, so give up if they
                # never stop.
                cur.connection.rollback()
                tic_failures += 1
                print(f"dropped a game tic: {exc.__class__.__name__}: "
                      f"{str(exc).splitlines()[0]}")
                if tic_failures >= 30:
                    raise
                break
            game_sql_seconds += tic_result.sql_seconds
            game_audio_seconds += tic_result.audio_seconds
            snapshot = tic_result.snapshot
            sound_events = tic_result.sound_events
            sound_loops = tic_result.sound_loops
            if sound_events is not None:
                if sound_events:
                    session.last_sound_event_id = max(
                        int(row[0]) for row in sound_events
                    )
                    play_sound_events(sound_events, sound_bank)
                sync_sound_loops(
                    sound_loops, sound_bank, session.active_sound_loops,
                )
            session.x, session.y = snapshot["x"], snapshot["y"]
            session.z, session.angle = snapshot["z"], snapshot["angle"]
            session.alive = snapshot["alive"]
            # The computer area map, once taken, shows the rest of the level.
            if demo_active and not snapshot["demo_active"]:
                # The recording ran out; in the attract loop SQL has already
                # put the title back up for the loop's next page.
                print("[demo] finished")
                demo_active = False
                if attract_on:
                    menu_screen = "title"
                    menu_state = sql.screen_state(cur)
                    invalidate_sql_screen()
            stage_mask = snapshot.get("tic_stages", 0)
            if stage_mask:
                fired_now = time.perf_counter()
                for stage_bit, _stage_name, _stage_group in TIC_STAGES:
                    if stage_mask & stage_bit:
                        session.tic_stage_fired[stage_bit] = fired_now
            if snapshot["use_locked"]:
                print(f"Door requires the {snapshot['required_key']} key")
            if JOIN_SLOT:
                pass  # no level exits in a deathmatch; the server owns the world
            elif snapshot["use_exit"]:
                deferred_exit_secret = snapshot["use_secret_exit"]
            elif snapshot["cross_exit"]:
                deferred_exit_secret = snapshot["cross_secret_exit"]
            elif snapshot["sector_exit"] or snapshot["boss_exit"]:
                # The two exits the world takes on its own: E1M8's boss floor
                # wearing the player down, and the last boss dying on E2M8 and
                # E3M8. Neither has a linedef behind it, and neither is ever a
                # secret exit.
                deferred_exit_secret = False
            if deferred_exit_secret is not None:
                # Say which of the four ended the level. An exit is a big,
                # irreversible transition and there are four separate routes
                # into it, so when one fires unexpectedly this line is the
                # difference between guessing and knowing.
                reason = ("use" if snapshot["use_exit"] else
                          "crossed line" if snapshot["cross_exit"] else
                          "boss floor" if snapshot["sector_exit"] else
                          "last boss died")
                print(f"[exit] {active_stage['label']} finished via {reason}"
                      f" -- health {snapshot_health(cur, map_id, player_thing_id)}"
                      f" secret={deferred_exit_secret}")
            if deferred_exit_secret is not None:
                session.physics_accumulator = 0.0
                break

        # Avoid an unbounded catch-up spiral if the client was stalled.
        if physics_tics == MAX_TICS_PER_FRAME:
            session.physics_accumulator = min(
                session.physics_accumulator, doom_config.TIC_SECONDS,
            )

        # Render every iteration. The renderer draws the pose we hand it, so
        # frames between tics show the camera part-way through its next step
        # instead of repeating the last tic's view.
        #
        # Except while a full-screen SQL composite is up. A menu or the
        # intermission hides the 3-D view completely and pauses gameplay, so
        # the pose cannot even change -- but this used to keep a ~25 ms frame
        # render and a stats+plan fetch in flight for every display frame of a
        # menu. That is what made the menus feel heavy: the menu's own 6 ms
        # composite had to queue behind them on the same server. The frame
        # after the screen closes issues the request again.
        if menu_screen is None and not inter_active and not finale_active:
            render_alpha = min(1.0, session.physics_accumulator / doom_config.TIC_SECONDS)
            if sql.API_MODE:
                # The server interpolates from the alpha the renderer sends,
                # so no pose makes the round trip; this one is for the dock
                # and for a failed render's log line.
                render_pose = (session.x, session.y, session.z, session.angle)
            else:
                render_pose = sql.camera_pose(
                    cur, map_id, player_thing_id, render_alpha,
                ) or (session.x, session.y, session.z, session.angle)
            renderer.request(render_pose, alpha=render_alpha)
            if not perf_mode:
                stats_worker.request(render_pose)

        if game_sql_seconds > 0.0:
            tic_count = max(1, physics_tics)
            if tic_warmup_pending:
                tic_warmup_pending = False
            else:
                gameplay_sql_history.append((
                    time.perf_counter(),
                    game_sql_seconds * 1000.0 / tic_count,
                    game_audio_seconds * 1000.0 / tic_count,
                ))

        # Consume finished frames without ever waiting for the SQL renderer.
        render = renderer.poll(cached_frame_id)

        if render.frame is not None:
            cached_base_surface = pygame.image.frombuffer(
                render.frame, (SCREEN_W, SCREEN_H), "RGB",
            )
            cached_scaled_surface = pygame.transform.scale(
                cached_base_surface, scaled_size(window_scale)
            )
            cached_frame_id = render.frame_id
            if render.render_seconds > 0.0:
                sql_frame_completions.append(render.completed_at)

        now = time.perf_counter()
        # SQL FPS is completed-frame throughput, sampled four times per second
        # over a trailing one-second window. Unlike 1/query_duration, this
        # correctly becomes zero when no SQL frame completes for a full second.
        while sql_next_rate_sample <= now:
            window_start = sql_next_rate_sample - 1.0
            while (sql_frame_completions
                   and sql_frame_completions[0] <= window_start):
                sql_frame_completions.popleft()
            completed = sum(
                completed_at <= sql_next_rate_sample
                for completed_at in sql_frame_completions
            )
            sql_fps_history.append((sql_next_rate_sample, float(completed)))
            sql_next_rate_sample += 0.25
        while (sql_frame_completions
               and sql_frame_completions[0] <= now - 1.0):
            sql_frame_completions.popleft()
        sql_fps = float(len(sql_frame_completions))
        while sql_fps_history and sql_fps_history[0][0] < now - 30.0:
            sql_fps_history.popleft()
        while (gameplay_sql_history
               and gameplay_sql_history[0][0] < now - 30.0):
            gameplay_sql_history.popleft()
        # Read before anything draws: the in-view readout wants it, and so
        # does the dock further down.
        recent_tic = (gameplay_sql_history[-1][1]
                      if gameplay_sql_history else None)
        if menu_screen is not None:
            # Blink on Doom's 8-tic step, and make that step part of the cache
            # key so the screen is only recomposited when it actually changes.
            skull_step = int(now * doom_config.TICS_PER_SECOND) // 8
            draw_sql_screen(
                window, cur,
                ("menu", menu_screen, menu_state["cursor"],
                 menu_state["episode"], menu_state["skill"],
                 skull_step % 2),
                skull_step,
            )
        elif inter_active:
            # Every figure on this screen was counted by SQL and every pixel
            # composited by SQL; the client only decides when to repaint, and
            # the figures themselves are the key that says when. There is no
            # Python tally behind this any more: if SQL cannot composite the
            # screen the window simply keeps the frame it already has, and the
            # next display frame tries again.
            draw_sql_screen(window, cur, ("inter",) + inter_figures, 0)
        elif finale_active:
            # The page only changes once every TEXTSPEED tics, so the number
            # of characters shown -- not the raw tic -- is what keys it.
            draw_sql_screen(
                window, cur, ("finale", finale_key[0], finale_key[1] // 3), 0,
            )
        elif modal is Modal.AUTOMAP:
            draw_sql_screen(
                window, cur,
                ("automap", round(session.x, 1), round(session.y, 1),
                 round(session.angle, 1)),
                0,
                automap=(map_id, player_thing_id),
            )
        else:
            if cached_scaled_surface is not None:
                window.blit(cached_scaled_surface, (0, 0))
            else:
                window.fill((0, 0, 0))

            if modal is Modal.NONE:
                draw_fps_badge(window, hud_font, sql_fps, recent_tic)
        if render.error and not inter_active:
            draw_text_shadow(
                window, font, f"Render error: {render.error}",
                (255, 96, 96), (8, 8)
            )
        # The dock is permanent: drawn last, after every modal and overlay, so
        # nothing can cover the part of the screen that explains the demo.
        if perf_mode:
            # Nothing samples these in performance mode, and nothing draws
            # them either -- the dock has no width and there is no band -- so
            # do not even take the worker's lock for them.
            worker_stats, worker_seconds, worker_plan = None, 0.0, None
        else:
            worker_stats, worker_seconds = stats_worker.poll()
            worker_plan = stats_worker.poll_plan()
        _, plan_rect = draw_sql_dock(
            display, window.get_width(), window_scale, dock_font_set,
            worker_stats, worker_seconds, sql_fps,
            render.render_seconds * 1000.0, now, sql_fps_history, worker_plan,
            recent_tic, gameplay_sql_history,
        )
        # Drawn on the display rather than into the cached panel: the replay
        # animates every frame while the panel behind it repaints rarely.
        if plan_rect is not None and worker_plan is not None:
            draw_plan_replay(display, plan_rect, worker_plan, now)
        if band_rect is not None:
            # The tic rack is a wide, short thing -- 18 cells in a row -- so it
            # takes a strip across the whole bottom of the band and leaves the
            # two tall panels above it.
            rack_h = min(round(band_rect.height * 0.30),
                         dock_font_set["heading"].get_linesize()
                         + dock_font_set["small"].get_linesize() + 30)
            # band_rect is the window's layout, computed once at open_window and
            # reused every frame -- shrinking IT here shrank the band again on
            # every frame, walking the rack up the screen and leaving a copy
            # behind each time. The per-frame split goes in its own name.
            panels_rect = band_rect
            if rack_h >= 34:
                rack_rect = pygame.Rect(
                    band_rect.left, band_rect.bottom - rack_h,
                    band_rect.width, rack_h)
                panels_rect = pygame.Rect(band_rect.left, band_rect.top,
                                          band_rect.width,
                                          band_rect.height - rack_h)
                draw_tic_rack(display, rack_rect, session.tic_stage_fired,
                              now, dock_font_set, recent_tic)
            tree_rect = panels_rect
            if map_geometry is not None:
                # The map gets exactly the width its own aspect needs; the tree
                # takes what is left, which is the shape a tree wants anyway.
                mx0, my0, mx1, my1 = map_geometry["bounds"]
                aspect = (mx1 - mx0) / max(1.0, my1 - my0)
                map_width = min(round(panels_rect.height * aspect) + 24,
                                panels_rect.width // 2)
                map_rect = pygame.Rect(panels_rect.left, panels_rect.top,
                                       map_width, panels_rect.height)
                tree_rect = pygame.Rect(
                    panels_rect.left + map_width, panels_rect.top,
                    panels_rect.width - map_width, panels_rect.height)
                draw_map_cull(
                    display, map_rect, map_geometry,
                    worker_stats["bsp_subsectors"] if worker_stats
                    else frozenset(),
                    (session.x, session.y, session.z, session.angle),
                    dock_font_set, worker_stats,
                )
            draw_pipeline_graph(display, tree_rect, worker_stats,
                                dock_font_set)
        pygame.display.flip()

    renderer.close()
    stats_worker.close()
    if pygame.mixer.get_init() is not None:
        pygame.mixer.music.stop()
    pygame.quit()
    cur.close()
    conn.close()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
