"""Prepared SQL adapter for the thin pygame client.

Gameplay itself lives in the SQL/CedarScript runtime installed by the WAD
loader.  This module owns the remaining database plumbing so doom_client.py
only deals with devices, presentation, and scheduling.
"""

import json
import os
import psycopg2.errors

from functools import cache
from pathlib import Path


ROOT = Path(__file__).resolve().parent / "sql"

RENDER_STATEMENT = "doom_render_frame"
RENDER_FOLDED_STATEMENT = "doom_render_frame_folded"
RENDER_STATS_STATEMENT = "doom_render_stats"
RESET_STATEMENT = "doom_reset_stage_call"
SPAWN_STATEMENT = "doom_spawn_player"
CARRY_STATEMENT = "doom_carry_player_call"
SCREEN_STATEMENT = "doom_render_screen"
MENU_INPUT_STATEMENT = "doom_menu_input_call"
SAVE_STATEMENT = "doom_save_game_call"
LOAD_STATEMENT = "doom_load_game_call"
INTER_BEGIN_STATEMENT = "doom_intermission_begin_call"
INTER_TIC_STATEMENT = "doom_intermission_tic_call"
INTER_ACCEL_STATEMENT = "doom_intermission_accel_call"
FINALE_BEGIN_STATEMENT = "doom_finale_begin_call"
FINALE_TIC_STATEMENT = "doom_finale_tic_call"
FINALE_ADVANCE_STATEMENT = "doom_finale_advance_call"
AUTOMAP_STATEMENT = "doom_render_automap"
SPAWN_POSE_STATEMENT = "doom_spawn_pose"
SOUND_EVENTS_STATEMENT = "doom_sound_events"
SOUND_LOOPS_STATEMENT = "doom_sound_loops"
SECRET_STATEMENT = "doom_level_secret"
FINISH_STATEMENT = "doom_level_finish"
LEVEL_STATS_STATEMENT = "doom_level_stats"
SNAPSHOT_STATEMENT = "doom_game_tick_finish"
GAME_TIC_STATEMENT = "doom_game_tic"
MP_START_STATEMENT = "doom_mp_start"
MP_TIC_STATEMENT = "doom_mp_tic"
MP_INPUT_STATEMENT = "doom_mp_input"
MP_PLAYERS_STATEMENT = "doom_mp_players"
MP_SCORE_STATEMENT = "doom_mp_score"
MP_REAP_STATEMENT = "doom_mp_reap"
CAMERA_STATEMENT = "doom_camera_pose"
CHEAT_ARSENAL_STATEMENT = "doom_cheat_arsenal"
CHEAT_CODE_STATEMENT = "doom_cheat_code"
MUSIC_STATEMENT = "doom_stage_music"
WEAPON_SLOT_STATEMENT = "doom_select_weapon_slot"
WEAPON_CYCLE_STATEMENT = "doom_cycle_weapon"
DEMO_HEADER_STATEMENT = "doom_demo_header"
DEMO_BEGIN_STATEMENT = "doom_demo_begin_call"
DEMO_PLAY_STATEMENT = "doom_demo_play_call"
DEMO_STOP_STATEMENT = "doom_demo_stop_call"
ATTRACT_START_STATEMENT = "doom_attract_start_call"
ATTRACT_STOP_STATEMENT = "doom_attract_stop_call"
ATTRACT_TIC_STATEMENT = "doom_attract_tic_call"
LEVEL_EXIT_STATEMENT = "doom_level_exit_call"
AFTER_INTER_STATEMENT = "doom_after_intermission_call"
ENTER_LEVEL_STATEMENT = "doom_enter_level_call"
CHEAT_KEY_STATEMENT = "doom_cheat_key_call"


# Player-API mode: the connection is an unprivileged deathmatch player role
# (see scripts/setup_roles.py) and every statement below goes through the
# api_* views and SECURITY DEFINER functions instead of the tables. Same
# function names, same return shapes, so the client does not care which.
API_MODE = False
API_JOIN_STATEMENT = "doom_api_join"
API_CAMERA_STATEMENT = "doom_api_camera"


@cache
def load_sql(filename):
    return (ROOT / filename).read_text(encoding="utf-8")


def load_stages(cur):
    cur.execute("SELECT * FROM api_stages" if API_MODE
                else load_sql("client/stages.sql"))
    rows = cur.fetchall()
    multiple_wads = len({row[2] for row in rows}) > 1
    return [
        {
            "map_id": int(map_id),
            "label": (f"{name} — {Path(wad_path).name}"
                      if multiple_wads else name),
            "player_thing_id": int(player_id),
        }
        for map_id, name, wad_path, player_id in rows
    ]


def load_automap(cur, map_id):
    if API_MODE:
        cur.execute("SELECT * FROM api_map_lines")
    else:
        cur.execute(load_sql("client/automap.sql"), (map_id,))
    rows = cur.fetchall()
    return {
        "lines": [tuple(row[:7]) for row in rows],
        "bounds": tuple(rows[0][7:]) if rows else (0, 0, 0, 0),
    }


def fetch_sound_assets(cur):
    cur.execute(load_sql("client/sound_assets.sql"))
    return cur.fetchall()


def prepare_statement(cur, name, parameter_types, statement):
    signature = f"({','.join(parameter_types)})" if parameter_types else ""
    cur.execute(f"PREPARE {name}{signature} AS {statement}")


def execute_prepared(cur, name, params=()):
    arguments = f"({','.join(['%s'] * len(params))})" if params else ""
    cur.execute(f"EXECUTE {name}{arguments}", params)


def _api_camera_statement():
    """client/camera_pose.sql over the caller's own row: alpha is the only parameter."""
    body = load_sql("client/camera_pose.sql")
    body = body.replace("FROM player_state ps", "FROM api_player_state ps")
    body = body.replace("WHERE ps.map_id = $1 AND ps.player_thing_id = $2", "")
    return body.replace("$3", "$1")


def set_session_parallel(cur, value):
    """SET max_parallel_workers for this if where the server has it (newer CedarDB builds); silently nothing elsewhere."""
    if not value:
        return False
    try:
        cur.execute(f"SET max_parallel_workers = {int(value)}")
    except psycopg2.Error:
        cur.connection.rollback()
        return False
    try:
        cur.execute("SHOW max_parallel_workers")
        row = cur.fetchone()
    except psycopg2.Error:
        cur.connection.rollback()
        return False
    try:
        return bool(row) and int(row[0]) == int(value)
    except (TypeError, ValueError):
        return False


def set_session_async_commit(cur):
    try:
        cur.execute("SET async_commit = on")
        return True
    except psycopg2.Error:
        cur.connection.rollback()
        return False


def prepare_api_client(cur):
    """The player role's statements: views and definer functions only."""
    set_session_parallel(cur, os.getenv("DOOM_CLIENT_PARALLEL", ""))
    for name, types, statement in (
        (API_JOIN_STATEMENT, (), "SELECT api_join()"),
        (SNAPSHOT_STATEMENT, (), "SELECT * FROM api_snapshot"),
        (CAMERA_STATEMENT, ("float8",), _api_camera_statement()),
        (SOUND_EVENTS_STATEMENT, ("bigint",),
         "SELECT * FROM api_sound_events WHERE event_id > $1 ORDER BY event_id"),
        (SOUND_LOOPS_STATEMENT, (), "SELECT * FROM api_sound_loops"),
        (MUSIC_STATEMENT, (), "SELECT * FROM api_stage_music"),
        (WEAPON_SLOT_STATEMENT, ("int",), "SELECT api_weapon_slot($1)"),
        (WEAPON_CYCLE_STATEMENT, ("int",), "SELECT api_weapon_cycle($1)"),
        (AUTOMAP_STATEMENT, (), "SELECT api_automap()"),
        (MP_INPUT_STATEMENT, ("real", "real", "boolean", "real", "boolean", "int", "boolean"),
         "SELECT api_input($1,$2,$3,$4,$5,$6,$7)"),
    ):
        prepare_statement(cur, name, types, statement)


def prepare_client(cur):
    set_session_async_commit(cur)
    if API_MODE:
        prepare_api_client(cur)
        return
    specs = (
        (RESET_STATEMENT, ("int", "int"),
         "SELECT doom_reset_stage($1,$2)"),
        (CARRY_STATEMENT, ("int", "int", "int", "int"),
         "SELECT doom_carry_player($1,$2,$3,$4)"),
        (SCREEN_STATEMENT, ("int",), load_sql("client/render_screen.sql")),
        (MENU_INPUT_STATEMENT, ("text",), "SELECT doom_menu_input($1)"),
        (SAVE_STATEMENT, ("int", "int", "int", "int", "text"),
         "SELECT doom_save_game($1,$2,$3,$4,$5)"),
        (LOAD_STATEMENT, ("int",), "SELECT doom_load_game($1)"),
        (INTER_BEGIN_STATEMENT, ("int", "int", "boolean"),
         "SELECT doom_intermission_begin($1,$2,$3)"),
        (INTER_TIC_STATEMENT, (), "SELECT doom_intermission_tic()"),
        (INTER_ACCEL_STATEMENT, (), "SELECT doom_intermission_accelerate()"),
        (FINALE_BEGIN_STATEMENT, ("int",),
         "SELECT doom_finale_begin($1)"),
        (FINALE_TIC_STATEMENT, (), "SELECT doom_finale_tic()"),
        (FINALE_ADVANCE_STATEMENT, (), "SELECT doom_finale_advance()"),
        (AUTOMAP_STATEMENT, ("int", "int"),
         load_sql("client/render_automap.sql")),
        (SPAWN_STATEMENT, ("int", "int"),
         "SELECT doom_spawn_player($1,$2)"),
        (SPAWN_POSE_STATEMENT, ("int", "int"),
         load_sql("client/spawn_pose.sql")),
        (SECRET_STATEMENT, ("int", "int"),
         "SELECT doom_cs_secret($1,$2)"),
        (FINISH_STATEMENT, ("int", "int", "boolean"),
         "SELECT doom_finish_level($1,$2,$3)"),
        (LEVEL_STATS_STATEMENT, ("int", "int"),
         load_sql("client/level_stats.sql")),
        (CHEAT_ARSENAL_STATEMENT, ("int", "int"),
         "SELECT doom_cheat_arsenal($1,$2)"),
        (CHEAT_CODE_STATEMENT, ("int", "int", "text"),
         "SELECT doom_cheat($1,$2,$3)"),
        (SNAPSHOT_STATEMENT, ("int", "int"),
         load_sql("client/game_tick_finish.sql")),
        (CAMERA_STATEMENT, ("int", "int", "float8"),
         load_sql("client/camera_pose.sql")),
        # Deathmatch: the server starts a match and runs its tic; clients
        # append input and look up which Thing their slot is.
        (MP_START_STATEMENT, ("int", "int"), "SELECT doom_mp_start($1,$2)"),
        (MP_TIC_STATEMENT, ("int", "int", "int", "int", "int", "int"),
         "SELECT doom_run_mp_tic($1,$2,$3,$4,$5,$6)"),
        (MP_INPUT_STATEMENT,
         ("int", "int", "real", "real", "boolean", "real", "boolean", "int",
          "boolean"),
         "INSERT INTO mp_inputs (map_id,player_thing_id,move_fwd,move_strafe,"
         "running,turn_degrees,attack_held,weapon_switch_to,use_requested) "
         "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)"),
        (MP_PLAYERS_STATEMENT, ("int",),
         "SELECT slot, player_thing_id FROM mp_players WHERE map_id=$1 "
         "ORDER BY slot"),
        (MP_REAP_STATEMENT, ("int", "int"), "SELECT doom_mp_reap($1,$2)"),
        (MP_SCORE_STATEMENT, ("int",),
         "SELECT mp.slot, ps.frags, ps.health, ps.alive, mp.role_name FROM mp_players mp "
         "JOIN player_state ps ON ps.map_id=mp.map_id "
         "AND ps.player_thing_id=mp.player_thing_id "
         "WHERE mp.map_id=$1 ORDER BY mp.slot"),
        (SOUND_EVENTS_STATEMENT, ("int", "int", "int", "bigint"),
         load_sql("client/sound_events.sql")),
        (SOUND_LOOPS_STATEMENT, ("int", "int"),
         load_sql("client/sound_loops.sql")),
    )
    for name, parameter_types, statement in specs:
        prepare_statement(cur, name, parameter_types, statement)
    prepare_statement(cur, GAME_TIC_STATEMENT, (
        "int", "int", "int", "real", "real", "boolean", "real",
        "boolean", "int", "boolean",
    ), """SELECT doom_run_game_tic(
      $1,$2,$3,$4,$5,$6,$7,$8,$9,$10)""")
    prepare_statement(
        cur, WEAPON_SLOT_STATEMENT, ("int", "int", "int"),
        load_sql("client/weapon_slot.sql"),
    )
    prepare_statement(
        cur, WEAPON_CYCLE_STATEMENT, ("int", "int", "int"),
        load_sql("client/weapon_cycle.sql"),
    )
    for name, types, statement in (
        (DEMO_HEADER_STATEMENT, ("int",), load_sql("client/demo_header.sql")),
        (DEMO_BEGIN_STATEMENT, ("text", "int", "int", "int"),
         "SELECT doom_demo_begin($1,$2,$3,$4)"),
        (DEMO_PLAY_STATEMENT, ("text",), "SELECT doom_demo_play($1)"),
        (DEMO_STOP_STATEMENT, (), "SELECT doom_demo_stop()"),
        (ATTRACT_START_STATEMENT, (), "SELECT doom_attract_start()"),
        (ATTRACT_STOP_STATEMENT, (), "SELECT doom_attract_stop()"),
        (ATTRACT_TIC_STATEMENT, (), "SELECT doom_attract_tic()"),
        (LEVEL_EXIT_STATEMENT, ("int", "int", "boolean"),
         "SELECT doom_level_exit($1,$2,$3)"),
        (AFTER_INTER_STATEMENT, ("int",), "SELECT doom_after_intermission($1)"),
        (ENTER_LEVEL_STATEMENT, ("int", "int", "int", "int", "int"),
         "SELECT doom_enter_level($1,$2,$3,$4,$5)"),
        (CHEAT_KEY_STATEMENT, ("int", "int", "text"),
         "SELECT doom_cheat_key($1,$2,$3)"),
    ):
        prepare_statement(cur, name, types, statement)
    prepare_statement(
        cur, MUSIC_STATEMENT, ("int",), load_sql("client/stage_music.sql"),
    )


def execute_game_tic(cur, map_id, player_id, command):
    execute_prepared(cur, GAME_TIC_STATEMENT, (map_id, player_id, *command))
    row = cur.fetchone()
    if row is None:
        raise RuntimeError("SQL game tic returned no result")
    return bool(row[0])


def mp_start(cur, map_id, skill):
    """Set up a two-player deathmatch on the map; returns the slot->thing map."""
    execute_prepared(cur, MP_START_STATEMENT, (map_id, skill))
    cur.fetchone()
    return mp_players(cur, map_id)


def mp_players(cur, map_id):
    execute_prepared(cur, MP_PLAYERS_STATEMENT, (map_id,))
    return {int(slot): int(thing) for slot, thing in cur.fetchall()}


def api_join(cur):
    """This role's player Thing in the open match, or None when none is open or
    every slot is taken. A claim racing the referee's tic or another join can
    fail to serialize; that is "not yet" as well, and the caller asks again."""
    try:
        execute_prepared(cur, API_JOIN_STATEMENT, ())
        row = cur.fetchone()
    except psycopg2.errors.SerializationFailure:
        cur.connection.rollback()
        return None
    return None if row is None or int(row[0]) < 0 else int(row[0])


def player_pose(cur, map_id, player_id):
    """(x, y, angle, z, alive) of a player as SQL has it, or None."""
    if API_MODE:
        cur.execute("SELECT position_x, position_y, view_angle, view_z, alive "
                    "FROM api_player_state")
    else:
        cur.execute("SELECT position_x, position_y, view_angle, view_z, alive "
                    "FROM player_state WHERE map_id=%s AND player_thing_id=%s",
                    (map_id, player_id))
    row = cur.fetchone()
    return None if row is None else (float(row[0]), float(row[1]), float(row[2]),
                                     float(row[3]), bool(row[4]))


def mp_tic(cur, map_id, skill, players):
    """One deathmatch tic. players: {slot: player_thing_id} for the occupied
    slots 1..4 (slot 1 required; missing slots are passed as NULL). True when
    this tic ended the level (-timer, an exit line): time for the
    intermission and doom_mp_rotate."""
    execute_prepared(cur, MP_TIC_STATEMENT,
                     (map_id, skill, players[1], players.get(2), players.get(3), players.get(4)))
    row = cur.fetchone()
    return bool(row and row[0])


def mp_push_input(cur, map_id, player_id, command):
    """Append one client frame's input; the server folds them per tic."""
    (_skill, move_fwd, move_strafe, running, turn, attack, weapon,
     use) = command
    values = (float(move_fwd), float(move_strafe), bool(running), float(turn),
              bool(attack), weapon, bool(use))
    if API_MODE:
        # The definer function binds the caller's own slot; no ids cross.
        execute_prepared(cur, MP_INPUT_STATEMENT, values)
        cur.fetchone()
    else:
        execute_prepared(cur, MP_INPUT_STATEMENT, (map_id, player_id, *values))


def mp_score(cur, map_id):
    execute_prepared(cur, MP_SCORE_STATEMENT, (map_id,))
    return cur.fetchall()


def mp_reap(cur, map_id, idle_seconds):
    """Free every slot whose holder has been silent for idle_seconds."""
    execute_prepared(cur, MP_REAP_STATEMENT, (map_id, idle_seconds))
    return int(cur.fetchone()[0])


def camera_pose(cur, map_id, player_id, alpha):
    """The interpolated camera (x, y, z, angle) for a frame `alpha` of a tic
    past the last one; None when the player has no state yet."""
    execute_prepared(cur, CAMERA_STATEMENT,
                     (float(alpha),) if API_MODE else (map_id, player_id, float(alpha)))
    row = cur.fetchone()
    return None if row is None else tuple(float(v) for v in row)


def finish_game_tic(cur, map_id, player_id):
    execute_prepared(cur, SNAPSHOT_STATEMENT, (map_id, player_id))
    row = cur.fetchone()
    if row is None:
        raise RuntimeError("SQL game tic did not produce a player snapshot")
    return {
        "x": float(row[0]), "y": float(row[1]), "angle": float(row[2]),
        "z": float(row[3]),
        "alive": bool(row[4]), "use_locked": bool(row[5]),
        "required_key": row[6], "use_exit": bool(row[7]),
        "use_secret_exit": bool(row[8]), "cross_exit": bool(row[9]),
        "cross_secret_exit": bool(row[10]),
        # Exits the world takes by itself: the boss floor wearing the player
        # down (E1M8) and the last boss dying (E2M8/E3M8).
        "sector_exit": bool(row[11]), "boss_exit": bool(row[12]),
        "power_map": bool(row[13]),
        "tic_stages": int(row[14] or 0),
        # Which full-screen state SQL has up, and whether a demo is driving
        # the input (41_flow.sql); the client mirrors both.
        "screen": row[15],
        "demo_active": bool(row[16]),
    }


def spawn_stage(cur, stage):
    key = (stage["map_id"], stage["player_thing_id"])
    execute_prepared(cur, SPAWN_STATEMENT, key)
    cur.fetchone()
    execute_prepared(cur, SPAWN_POSE_STATEMENT, key)
    row = cur.fetchone()
    if row is None:
        raise RuntimeError("SQL could not resolve the selected player start")
    return tuple(float(value) for value in row)


def intermission_begin(cur, map_id, player_id, secret_exit):
    """Enter the intermission and resolve the next level, all in SQL.

    Returns the next map_id, or None when the episode ends here or that map
    is not loaded.
    """
    execute_prepared(cur, INTER_BEGIN_STATEMENT,
                     (int(map_id), int(player_id), bool(secret_exit)))
    row = cur.fetchone()
    nxt = None if row is None else int(row[0])
    return None if nxt is None or nxt < 0 else nxt


def intermission_tic(cur):
    """One 35 Hz step of the tally. Returns (status, displayed figures).

    status is 'counting', 'waiting' (all shown) or 'done' (dismissed).
    """
    execute_prepared(cur, INTER_TIC_STATEMENT, ())
    row = cur.fetchone()
    status = "done" if row is None else (row[0] or "done")
    cur.execute("SELECT sp_state,kills_pct,items_pct,secrets_pct,"
                "time_secs,par_secs FROM screen_state WHERE id=0")
    figures = cur.fetchone() or (0, 0, 0, 0, 0, 0)
    return status, tuple(int(v) for v in figures)


def intermission_accelerate(cur):
    execute_prepared(cur, INTER_ACCEL_STATEMENT, ())
    cur.fetchone()


def finale_begin(cur, episode):
    """Enter the end-of-episode finale. False if this episode has no text."""
    execute_prepared(cur, FINALE_BEGIN_STATEMENT, (int(episode),))
    row = cur.fetchone()
    return bool(row and int(row[0]))


def finale_tic(cur):
    """One 35 Hz step. Returns 'text', 'picture' or 'done'."""
    execute_prepared(cur, FINALE_TIC_STATEMENT, ())
    row = cur.fetchone()
    return "done" if row is None else (row[0] or "done")


def finale_advance(cur):
    """A keypress: skip one step. Returns 'text', 'picture' or 'done'."""
    execute_prepared(cur, FINALE_ADVANCE_STATEMENT, ())
    row = cur.fetchone()
    return "done" if row is None else (row[0] or "done")


def render_automap(cur, map_id, player_id):
    """Composite one 320x200 automap frame. Same contract as render_frame."""
    execute_prepared(cur, AUTOMAP_STATEMENT,
                     () if API_MODE else (int(map_id), int(player_id)))
    row = cur.fetchone()
    return None if row is None else row[0]


def automap_pan(cur, map_id, player_id, dx, dy):
    _automap(cur, "pan", map_id, player_id, (float(dx), float(dy)))


def automap_zoom(cur, map_id, player_id, factor):
    _automap(cur, "zoom", map_id, player_id, (float(factor),))


def automap_toggle(cur, map_id, player_id, what):
    """what is 'follow', 'grid' or 'cheat'; cheat cycles 0 -> 1 -> 2 -> 0."""
    _automap(cur, "toggle", map_id, player_id, (str(what),))


def automap_fit(cur, map_id, player_id):
    _automap(cur, "fit", map_id, player_id, ())


def _automap(cur, action, map_id, player_id, args):
    if API_MODE:
        cur.execute(f"SELECT api_automap_{action}(" + ",".join(["%s"] * len(args)) + ")", args)
    else:
        cur.execute(f"SELECT doom_automap_{action}(%s,%s"
                    + "".join(",%s" for _ in args) + ")", (map_id, player_id, *args))
    cur.fetchone()


def finale_phase(cur):
    """(stage, count) -- the repaint key for the finale page."""
    cur.execute("SELECT finale_stage,finale_count FROM screen_state WHERE id=0")
    row = cur.fetchone()
    return (0, 0) if row is None else (int(row[0]), int(row[1]))


def save_game(cur, slot, map_id, player_id, skill, name):
    """Snapshot the current level into a slot.

    One function call, and a call is one transaction, so a save is atomic --
    a failure part-way leaves the slot as it was rather than half-written.
    """
    execute_prepared(cur, SAVE_STATEMENT,
                     (int(slot), int(map_id), int(player_id), int(skill), name))
    cur.fetchone()


def load_game(cur, slot):
    """Restore a slot. Returns the restored map_id, or None if it was empty.

    Atomic for the same reason as save_game: verified by corrupting a late
    table in a slot and confirming the tables restored before it were
    untouched afterwards.
    """
    execute_prepared(cur, LOAD_STATEMENT, (int(slot),))
    row = cur.fetchone()
    map_id = None if row is None else int(row[0])
    if map_id is None or map_id < 0:
        return None
    # The skill comes back with it: the restored world was seeded for one
    # particular skill, and the client must render and tick at that same
    # skill or it sees monsters with no health and no AI.
    cur.execute("SELECT skill FROM save_slots WHERE slot=%s", (int(slot),))
    got = cur.fetchone()
    return {"map_id": map_id, "skill": 2 if got is None else int(got[0])}


def render_screen(cur, tics):
    """The title/menu/intermission frame, as the same 320x200 RGB the
    renderer returns -- so the client blits menus and levels identically."""
    execute_prepared(cur, SCREEN_STATEMENT, (int(tics),))
    row = cur.fetchone()
    return None if row is None or row[0] is None else bytes(row[0])


def screen_state(cur):
    cur.execute("SELECT screen,cursor_index,episode,skill FROM screen_state "
                "WHERE id=0")
    row = cur.fetchone()
    if row is None:
        return {"screen": "game", "cursor": 0, "episode": 1, "skill": 2}
    return {"screen": row[0], "cursor": int(row[1]),
            "episode": int(row[2]), "skill": int(row[3])}


def menu_input(cur, key):
    """Feed one keypress to the SQL menu; returns (action, new state)."""
    execute_prepared(cur, MENU_INPUT_STATEMENT, (key,))
    row = cur.fetchone()
    action = "none" if row is None else (row[0] or "none")
    return action, screen_state(cur)


def set_screen(cur, screen):
    cur.execute("UPDATE screen_state SET screen=%s WHERE id=0", (screen,))


def carry_player(cur, from_map_id, from_player_id, map_id, player_id):
    """Move weapons/ammo/armor/health across a level exit, Doom-style.

    Call AFTER reset_stage + spawn_stage: those apply Doom's death loadout,
    and this copies the surviving state over the top of it.
    """
    execute_prepared(
        cur, CARRY_STATEMENT, (from_map_id, from_player_id, map_id, player_id),
    )


def reset_stage(cur, map_id, skill):
    execute_prepared(cur, RESET_STATEMENT, (map_id, skill))
    cur.fetchone()


def record_level_secret(cur, map_id, player_id):
    execute_prepared(cur, SECRET_STATEMENT, (map_id, player_id))
    cur.fetchone()


def finish_level(cur, map_id, player_id, secret_exit):
    execute_prepared(
        cur, FINISH_STATEMENT, (map_id, player_id, secret_exit),
    )
    cur.fetchone()
    execute_prepared(cur, LEVEL_STATS_STATEMENT, (map_id, player_id))
    row = cur.fetchone()
    keys = (
        "map_id", "name", "skill_bit", "level_tics", "par_tics",
        "kills", "total_kills", "items", "total_items",
        "secrets", "total_secrets", "secret_exit",
    )
    if row is None:
        raise RuntimeError("level stats row was not initialized by stage reset")
    return dict(zip(keys, row))


def fetch_sound_events(cur, map_id, player_id, after_event_id):
    if API_MODE:
        execute_prepared(cur, SOUND_EVENTS_STATEMENT, (after_event_id,))
        events = cur.fetchall()
        execute_prepared(cur, SOUND_LOOPS_STATEMENT, ())
        return events, cur.fetchall()
    execute_prepared(
        cur, SOUND_EVENTS_STATEMENT,
        (map_id, player_id, map_id, after_event_id),
    )
    events = cur.fetchall()
    execute_prepared(cur, SOUND_LOOPS_STATEMENT, (map_id, player_id))
    return events, cur.fetchall()


def fetch_stage_music(cur, map_id):
    execute_prepared(cur, MUSIC_STATEMENT, () if API_MODE else (map_id,))
    return cur.fetchone()


def cheat_give_arsenal(cur, map_id, player_id):
    execute_prepared(cur, CHEAT_ARSENAL_STATEMENT, (map_id, player_id))
    return int(cur.fetchone()[0])


def cheat_code(cur, map_id, player_id, code):
    """Apply one typed cheat code; returns the message Doom prints."""
    execute_prepared(cur, CHEAT_CODE_STATEMENT,
                     (int(map_id), int(player_id), str(code)))
    row = cur.fetchone()
    return None if row is None else (row[0] or None)


def select_weapon_slot(cur, map_id, player_id, slot):
    execute_prepared(cur, WEAPON_SLOT_STATEMENT,
                     (slot,) if API_MODE else (map_id, player_id, slot))
    row = cur.fetchone()
    return None if row is None or (API_MODE and int(row[0]) < 0) else int(row[0])


def demo_begin(cur, name, map_id, player_id, skill):
    """Start recording under this name (replacing any demo of that name)."""
    execute_prepared(cur, DEMO_BEGIN_STATEMENT, (name, map_id, player_id, skill))
    return int(cur.fetchone()[0])


def demo_play(cur, name):
    """Start playing the named demo; returns its header, or None if unknown."""
    execute_prepared(cur, DEMO_PLAY_STATEMENT, (name,))
    demo_id = int(cur.fetchone()[0])
    return None if demo_id < 0 else demo_header(cur, demo_id)


def demo_stop(cur):
    execute_prepared(cur, DEMO_STOP_STATEMENT, ())
    cur.fetchone()


def demo_header(cur, demo_id):
    execute_prepared(cur, DEMO_HEADER_STATEMENT, (int(demo_id),))
    row = cur.fetchone()
    if row is None:
        return None
    return {"demo_id": int(row[0]), "name": row[1], "map_id": int(row[2]),
            "player_thing_id": int(row[3]), "skill": int(row[4]),
            "tic_count": int(row[5])}


def attract_start(cur):
    execute_prepared(cur, ATTRACT_START_STATEMENT, ())
    cur.fetchone()


def attract_stop(cur):
    execute_prepared(cur, ATTRACT_STOP_STATEMENT, ())
    cur.fetchone()


def attract_tic(cur):
    """One 35 Hz step of the attract loop: 'none', 'page' or 'demo:<id>'."""
    execute_prepared(cur, ATTRACT_TIC_STATEMENT, ())
    row = cur.fetchone()
    return "none" if row is None else (row[0] or "none")


def level_exit(cur, map_id, player_id, secret_exit):
    """G_DoCompleted: freeze the tally and route; the next map_id or None."""
    execute_prepared(cur, LEVEL_EXIT_STATEMENT,
                     (int(map_id), int(player_id), bool(secret_exit)))
    row = cur.fetchone()
    nxt = None if row is None else int(row[0])
    return None if nxt is None or nxt < 0 else nxt


def after_intermission(cur, map_id):
    """'finale' or 'level:<map_id>', once the tally has been dismissed."""
    execute_prepared(cur, AFTER_INTER_STATEMENT, (int(map_id),))
    row = cur.fetchone()
    return "level:%d" % map_id if row is None else row[0]


def enter_level(cur, map_id, player_id, skill, carry_from=None):
    """G_DoLoadLevel in one call; returns the spawn pose (x, y, angle, z)."""
    from_map, from_player = carry_from if carry_from else (None, None)
    execute_prepared(cur, ENTER_LEVEL_STATEMENT,
                     (int(map_id), int(player_id), int(skill), from_map,
                      from_player))
    cur.fetchone()
    execute_prepared(cur, SPAWN_POSE_STATEMENT, (int(map_id), int(player_id)))
    row = cur.fetchone()
    if row is None:
        raise RuntimeError("SQL could not resolve the selected player start")
    return tuple(float(value) for value in row)


def cheat_key(cur, map_id, player_id, key):
    """One typed letter into the cheat buffer; what the client must act on."""
    execute_prepared(cur, CHEAT_KEY_STATEMENT, (int(map_id), int(player_id), key))
    row = cur.fetchone()
    return "none" if row is None else (row[0] or "none")


def cycle_weapon(cur, map_id, player_id, step):
    """The next (+1) or previous (-1) weapon the player owns."""
    execute_prepared(cur, WEAPON_CYCLE_STATEMENT,
                     (step,) if API_MODE else (map_id, player_id, step))
    row = cur.fetchone()
    return None if row is None or (API_MODE and int(row[0]) < 0) else int(row[0])


# Which connection has a folded renderer prepared, and for which world. Keyed
# by connection id and checked against the caller's own arguments, so a stale
# entry (a closed connection whose id got reused) can only ever miss and fall
# back to the general statement -- never render the wrong map.
_RENDER_FOLDED = {}


def _reprepare(cur, name, parameter_types, statement):
    """PREPARE that can be called again, so a level change can re-fold."""
    try:
        cur.execute(f"DEALLOCATE {name}")
    except Exception:
        # Not prepared on this connection yet, which is the normal first call.
        # This module deliberately does not import psycopg2, so the exception
        # type cannot be named here; nothing else can fail in a DEALLOCATE.
        cur.connection.rollback()
    prepare_statement(cur, name, parameter_types, statement)


def prepare_renderer(cur, map_id=None, player_id=None, skill=None):
    """Prepare the renderer, optionally folding the constants for one world.

    map_id, player_thing_id and skill change once per level; the camera pose
    changes every frame. Compiling them in as literals instead of parameters
    lets the planner fold them, which measures 2.0 ms a frame off a 26.6 ms
    render -- for one 24 ms preparation per level. The general seven-parameter
    form is always prepared too, so any caller that has not folded, or has
    moved to another map since, still works.
    """
    key = id(cur.connection)
    _RENDER_FOLDED.pop(key, None)
    if API_MODE:
        cur.execute("SELECT api_slot()")
        slot = int(cur.fetchone()[0])
        _reprepare(cur, RENDER_FOLDED_STATEMENT, (),
                   f"SELECT frame_rgb FROM api_frame_slot{slot}_m{int(map_id)}")
        _reprepare(cur, API_CAMERA_STATEMENT, ("float8",),
                   "SELECT api_camera($1)")
        _RENDER_FOLDED[key] = (int(map_id), int(player_id), int(skill))
        return
    body = load_sql("renderer.sql")
    _reprepare(
        cur, RENDER_STATEMENT,
        ("int", "int", "int", "float8", "float8", "float8", "float8"), body,
    )
    if map_id is None or player_id is None or skill is None:
        return
    folded = (body.replace("$1", str(int(map_id)))
                  .replace("$2", str(int(player_id)))
                  .replace("$3", str(int(skill))))
    # Renumber the pose in ascending order so no substitution collides with a
    # marker it has just written.
    for src, dst in (("$4", "$1"), ("$5", "$2"), ("$6", "$3"), ("$7", "$4")):
        folded = folded.replace(src, dst)
    _reprepare(
        cur, RENDER_FOLDED_STATEMENT,
        ("float8", "float8", "float8", "float8"), folded,
    )
    _RENDER_FOLDED[key] = (int(map_id), int(player_id), int(skill))


def _render_stats_statement():
    """The renderer's own pipeline, ending in a projection that counts it.

    Splicing at renderer.sql's @stats-cut marker keeps the two in step: the
    overlay can never report row counts for a pipeline that no longer matches
    the one drawing the frame.
    """
    body = load_sql("renderer.sql")
    marker = "-- @stats-cut"
    cut = body.index(marker)
    return body[:cut] + load_sql("client/render_stats_tail.sql")


def prepare_render_stats(cur):
    prepare_statement(
        cur, RENDER_STATS_STATEMENT,
        ("int", "int", "int", "float8", "float8", "float8", "float8"),
        _render_stats_statement(),
    )


RENDER_STATS_FIELDS = (
    "subsectors", "segs", "wall_spans", "wall_px", "plane_px", "sprite_px",
    "psprite_px", "fragments_ranked", "pixels_resolved", "holes",
    "view_px", "ui_px", "bsp_children", "bsp_kept",
    "things_in_view", "things_drawn",
)


def fetch_render_stats(cur, map_id, player_id, skill, pose):
    """Row counts for one frame of the renderer, plus what the BSP walk saw."""
    execute_prepared(
        cur, RENDER_STATS_STATEMENT, (map_id, player_id, skill, *pose),
    )
    row = cur.fetchone()
    if row is None:
        return None
    stats = dict(zip(RENDER_STATS_FIELDS,
                     (int(v or 0) for v in row[:len(RENDER_STATS_FIELDS)])))
    # The walked subsectors ride along as a set, for the plan view to light up.
    stats["bsp_subsectors"] = frozenset(row[len(RENDER_STATS_FIELDS)] or ())
    return stats


def fetch_map_geometry(cur, map_id):
    """Every seg's endpoints and subsector, for the top-down culling view.

    Static for the level. Solid (one-sided) segs are the level's outline; the
    rest are portals between sectors, and drawing them differently is what
    makes the plan view read as a map rather than a mesh.
    """
    if API_MODE:
        cur.execute("SELECT * FROM api_map_geometry")
    if not API_MODE:
        cur.execute(
            "SELECT x1, y1, x2, y2, ssector_id, (bsec IS NULL) AS solid "
            "FROM render_segs WHERE map_id = %s", (map_id,))
    segs = [(float(a), float(b), float(c), float(d), int(ss), bool(solid))
            for a, b, c, d, ss, solid in cur.fetchall()]
    if not segs:
        return None
    xs = [v for seg in segs for v in (seg[0], seg[2])]
    ys = [v for seg in segs for v in (seg[1], seg[3])]
    return {"segs": segs,
            "bounds": (min(xs), min(ys), max(xs), max(ys))}


# Children hang off these keys in the plan JSON, sometimes behind a wrapper
# object (a set operation's arguments are {columns, input} pairs), so the walk
# looks for the nearest operator nodes rather than assuming a fixed shape.
_PLAN_CHILD_KEYS = ("input", "left", "right", "magic", "pipelineBreaker",
                    "arguments")


def _plan_children(node):
    found = []

    def descend(value):
        if isinstance(value, dict):
            if "operatorId" in value and "operator" in value:
                found.append(value)
            else:
                for item in value.values():
                    descend(item)
        elif isinstance(value, list):
            for item in value:
                descend(item)

    for key in _PLAN_CHILD_KEYS:
        if key in node:
            descend(node[key])
    return found


def parse_plan(payload):
    """Plan JSON -> (nodes, edges, timeline).

    nodes carry the operator kind, depth and the rows it actually produced.
    timeline is the frame's execution: one entry per pipeline as
    (start_us, stop_us, [node indices]). CedarDB runs the pipelines one at a
    time -- measured peak concurrency is 1 -- so the timeline is a single
    sweep rather than overlapping windows.
    """
    plan = payload["plan"]
    nodes, edges = [], []

    def walk(raw, depth, parent):
        index = len(nodes)
        rows = raw.get("analyzePlanCardinality")
        if rows is None:
            rows = raw.get("cardinality") or 0
        nodes.append({"op": raw.get("operator", "?"), "depth": depth,
                      "rows": int(rows), "analyze_id": raw.get("analyzePlanId"),
                      "children": []})
        if parent is not None:
            nodes[parent]["children"].append(index)
            edges.append((parent, index))
        for child in _plan_children(raw):
            walk(child, depth + 1, index)

    walk(plan, 0, None)

    by_analyze = {}
    for index, node in enumerate(nodes):
        if node["analyze_id"] is not None:
            by_analyze.setdefault(node["analyze_id"], []).append(index)
    timeline = []
    for pipeline in payload.get("analyzePlanPipelines", ()):
        members = sorted({i for op in pipeline.get("operators", ())
                          for i in by_analyze.get(op, ())})
        if members:
            timeline.append((pipeline.get("start", 0), pipeline.get("stop", 0),
                             members))
    timeline.sort()
    return nodes, edges, timeline


def fetch_plan_graph(cur, map_id, player_id, skill, pose):
    """EXPLAIN (ANALYZE) the renderer at this pose and return its plan graph."""
    body = load_sql("renderer.sql").rstrip().rstrip(";")
    for token, value in (("$1", str(map_id)), ("$2", str(player_id)),
                         ("$3", str(skill)), ("$4", repr(float(pose[0]))),
                         ("$5", repr(float(pose[1]))),
                         ("$6", repr(float(pose[2]))),
                         ("$7", repr(float(pose[3])))):
        body = body.replace(token, value)
    cur.execute("EXPLAIN (ANALYZE, FORMAT JSON) " + body)
    row = cur.fetchone()
    if row is None:
        return None
    return parse_plan(json.loads(row[0]))


def render_frame(cur, map_id, player_id, skill, pose,
                 width=320, height=200, alpha=1.0):
    """Render one frame from an explicit camera pose (x, y, z, angle).

    The pose is a parameter rather than a lookup of the player Thing so the
    client can draw interpolated poses between the 35 Hz gameplay tics.
    """
    if API_MODE:
        if _RENDER_FOLDED.get(id(cur.connection)) != (map_id, player_id, skill):
            prepare_renderer(cur, map_id, player_id, skill)
        execute_prepared(cur, API_CAMERA_STATEMENT, (float(alpha),))
        cur.fetchone()
        execute_prepared(cur, RENDER_FOLDED_STATEMENT, ())
    elif _RENDER_FOLDED.get(id(cur.connection)) == (map_id, player_id, skill):
        execute_prepared(cur, RENDER_FOLDED_STATEMENT, tuple(pose))
    else:
        execute_prepared(
            cur, RENDER_STATEMENT, (map_id, player_id, skill, *pose),
        )
    row = cur.fetchone()
    if (row is None or len(row) != 1
            or not isinstance(row[0], (bytes, bytearray, memoryview))):
        raise ValueError(
            f"renderer did not return one packed RGB value at pose {pose}"
        )
    raw = bytes(row[0])
    expected = width * height * 3
    if len(raw) != expected:
        # Short almost always means the camera pose sits in no sector at all,
        # so the 3-D view contributed no pixels and only the status bar did.
        raise ValueError(
            f"renderer returned {len(raw)} packed RGB bytes, expected "
            f"{expected}, at pose {pose}"
        )
    return raw
