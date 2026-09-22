"""The diagnostics dock: what the SQL is doing, drawn beside the game.

Row counts sampled from the renderer's own pipeline (StatsWorker), the real
query plan as a live graph, the BSP cull view, the tic stage rack and the fps
badge. None of it touches gameplay; the client can run without it (F6).
"""
import math
import threading
import time

import psycopg2
import pygame

import doom_sql as sql
import doom_config
from doom_config import (TIC_STAGES, DB_DSN, SCREEN_W, load_constants, tune_replanning)


# The dock is measured in Doom's own 320x200 pixels and multiplied by the
# window scale, exactly like the status bar underneath it. That is the whole
# point: at any scale the panel's type is the same size as the game's type, so
# it never shrinks into a debug readout beside a giant Doom.
DOCK_DOOM_WIDTH = 96
DOCK_DOOM_FONTS = {
    "title": 11,
    "hero": 26,
    "row": 9,
    "heading": 7,
    "caption": 6,
    # For the funnel rows and the query caption: secondary detail that should
    # not compete with the numbers above it for weight.
    "small": 5,
}


def dock_width(scale):
    """Width of the permanent SQL panel beside the game, in real pixels."""
    if SCREEN_W * scale < 480:
        return 0
    return DOCK_DOOM_WIDTH * scale


# Cached because the string only changes a few times a second while the
# display loop runs at a hundred-plus, and performance mode is supposed to
# cost nothing.
_FPS_BADGE = {"text": None, "surface": None}


def draw_text_shadow(window, font, text, color, position):
    shadow = font.render(text, True, (0, 0, 0))
    label = font.render(text, True, color)
    window.blit(shadow, (position[0] + 1, position[1] + 1))
    window.blit(label, position)


def draw_fps_badge(view, font, sql_fps, tic_ms):
    """The one readout that is always on: SQL throughput, inside the view.

    Everything else -- the dock, the band, the charts -- goes away entirely in
    performance mode, and the F4 diagnostics panel that used to overlay the
    view is gone for good. This stays because it is the one number that says
    whether the database is keeping up, and it is read off work the loop has
    already done.
    """
    label = f"{sql_fps:.1f} SQL fps"
    if tic_ms is not None:
        label += f"   {tic_ms:.1f} ms tic"
    if _FPS_BADGE["text"] != label:
        _FPS_BADGE["text"] = label
        _FPS_BADGE["surface"] = font.render(label, True, (235, 178, 58))
    surface = _FPS_BADGE["surface"]
    pad = max(4, view.get_width() // 100)
    draw_text_shadow(view, font, label, (235, 178, 58),
                     (view.get_width() - surface.get_width() - pad, pad))


def dock_fonts(scale):
    """Fonts scaled with the game, then shrunk if a row would not fit.

    Sizing from Doom pixels keeps the panel's weight matched to the status bar
    at every scale, but the longest label plus its value still has to fit the
    column, so the row font is stepped down until it does.
    """
    width = dock_width(scale)
    fonts = {
        name: pygame.font.Font(None, max(12, doom_px * scale))
        for name, doom_px in DOCK_DOOM_FONTS.items()
    }
    if width:
        pad = max(4, DOCK_PAD_DOOM * scale)
        budget = width - pad * 2
        size = max(12, DOCK_DOOM_FONTS["row"] * scale)
        while size > 12:
            font = pygame.font.Font(None, size)
            widest = max(
                font.size(label)[0] + font.size("  ")[0]
                + font.size(sample)[0]
                for label, sample in DOCK_WIDEST_ROWS
            )
            if widest <= budget:
                break
            size -= 1
        fonts["row"] = pygame.font.Font(None, size)
    return fonts


DOCK_PAD_DOOM = 4

# The longest label/value pairs the panel can show, used to size the row font.
DOCK_WIDEST_ROWS = (
    ("fragments ranked", "000,000"),
    ("gameplay tics / s", "000"),
    ("pixels resolved", "000,000"),
)


DOCK_BG = (10, 11, 9)
DOCK_INK = (215, 211, 194)
DOCK_DIM = (140, 136, 120)
DOCK_ACCENT = (117, 211, 139)
DOCK_HOT = (235, 178, 58)

PLAN_KIND_COLOURS = {
    "join": (224, 145, 58), "pipelinebreakerscan": (79, 126, 168),
    "tablescan": (111, 191, 122), "select": (192, 91, 107),
    "map": (143, 123, 196), "groupby": (216, 195, 74),
    "temp": (90, 168, 160), "generateseries": (155, 162, 79),
    "setoperation": (199, 123, 176), "sort": (122, 139, 160),
    "inlinetable": (160, 139, 111), "window": (95, 158, 196),
}
PLAN_KIND_DEFAULT = (110, 116, 108)
# How much slower than reality the replay runs. At 1.0 the sweep takes exactly
# as long as the frame did -- about 34 ms, so the whole plan re-fires ~29 times
# a second and reads as a live shimmer. Raise it to watch the wave crawl; the
# relative timings are the measured ones either way.
PLAN_REPLAY_SLOWDOWN = 1.0

_DOCK_CACHE = {}
_PLAN_CACHE = {}


def plan_silhouette(plan, width, height):
    """Lay the plan out to fit a box and cache the static drawing.

    The tree's shape never changes between samples, so both the layout and the
    line work are computed once per (plan, size) and reused; only the replay
    highlight is drawn per frame.
    """
    nodes, edges, timeline = plan
    key = (id(plan), width, height)
    cached = _PLAN_CACHE.get("silhouette")
    if cached and cached[0] == key:
        return cached[1]

    cursor = [0]

    def place(index):
        node = nodes[index]
        if node["children"]:
            for child in node["children"]:
                place(child)
            node["ry"] = (nodes[node["children"][0]]["ry"]
                          + nodes[node["children"][-1]]["ry"]) / 2.0
        else:
            node["ry"] = cursor[0]
            cursor[0] += 1

    place(0)
    rows = max(1, cursor[0] - 1)
    depth = max(1, max(n["depth"] for n in nodes))
    for node in nodes:
        node["x"] = 2 + node["depth"] / depth * (width - 5)
        node["y"] = 2 + node["ry"] / rows * (height - 5)

    peak = max((n["rows"] for n in nodes), default=1) or 1
    log_peak = math.log10(1 + peak)
    surface = pygame.Surface((width, height))
    surface.fill((7, 8, 7))
    for parent, child in edges:
        a, b = nodes[parent], nodes[child]
        colour = PLAN_KIND_COLOURS.get(b["op"], PLAN_KIND_DEFAULT)
        pygame.draw.line(surface, tuple(round(c * 0.42) for c in colour),
                         (a["x"], a["y"]), (b["x"], b["y"]), 1)
    for node in nodes:
        node["r"] = 1.0 + 2.2 * math.log10(1 + node["rows"]) / log_peak
        pygame.draw.circle(
            surface, tuple(round(c * 0.72) for c in
                           PLAN_KIND_COLOURS.get(node["op"], PLAN_KIND_DEFAULT)),
            (node["x"], node["y"]), node["r"])
    span = (min(t[0] for t in timeline), max(t[1] for t in timeline))
    _PLAN_CACHE["silhouette"] = (key, (surface, span))
    return surface, span


def draw_plan_replay(target, rect, plan, now):
    """Replay the frame's pipelines through the silhouette, in order.

    CedarDB executes the pipelines one at a time, so this is a single sweep:
    whichever pipeline owned the clock at the replayed instant lights up, with
    the two before it fading out behind.
    """
    nodes, _edges, timeline = plan
    surface, (span_start, span_stop) = plan_silhouette(plan, rect.width,
                                                       rect.height)
    target.blit(surface, rect.topleft)
    if span_stop <= span_start:
        return
    # The loop lasts the frame's own measured duration, scaled only by the
    # slowdown factor, so a pipeline that took a third of the frame occupies a
    # third of the sweep.
    period = max(1e-4, (span_stop - span_start) / 1e6 * PLAN_REPLAY_SLOWDOWN)
    phase = (now % period) / period
    at = span_start + phase * (span_stop - span_start)
    active = None
    for index, (start, _stop, _) in enumerate(timeline):
        if start <= at:
            active = index
        else:
            break
    if active is None:
        return
    for back, weight in ((0, 1.0), (1, 0.45), (2, 0.2)):
        index = active - back
        if index < 0:
            continue
        for member in timeline[index][2]:
            node = nodes[member]
            colour = tuple(round(c + (255 - c) * weight * 0.8) for c in
                           PLAN_KIND_COLOURS.get(node["op"], PLAN_KIND_DEFAULT))
            pygame.draw.circle(
                target, colour,
                (rect.left + node["x"], rect.top + node["y"]),
                node["r"] + 1.6 * weight)


_GEO_CACHE = {}


def draw_map_cull(display, rect, geometry, walked, pose, fonts, stats=None):
    """The level from above, with the subsectors the BSP walk reached lit.

    The pipeline diagram beside this shows what the survivors cost; this shows
    which part of the map they were. Turn around and whole wings go dark.
    """
    segs = geometry["segs"]
    x0, y0, x1, y1 = geometry["bounds"]
    span_x, span_y = max(1.0, x1 - x0), max(1.0, y1 - y0)
    head = fonts["heading"].get_linesize() + 6
    inner = pygame.Rect(rect.left + 6, rect.top + head,
                        rect.width - 12, rect.height - head - 6)
    scale = min(inner.width / span_x, inner.height / span_y)
    off_x = inner.left + (inner.width - span_x * scale) / 2.0
    off_y = inner.top + (inner.height - span_y * scale) / 2.0

    def to_screen(wx, wy):
        # Doom's +y runs north; screen y runs down.
        return (off_x + (wx - x0) * scale, off_y + (y1 - wy) * scale)

    key = (id(geometry), rect.size)
    cached = _GEO_CACHE.get("surface")
    if not cached or cached[0] != key:
        surface = pygame.Surface(rect.size)
        surface.fill(DOCK_BG)
        for ax, ay, bx, by, _ssector, solid in segs:
            start, end = to_screen(ax, ay), to_screen(bx, by)
            pygame.draw.line(surface, (54, 60, 50) if solid else (32, 38, 32),
                             (start[0] - rect.left, start[1] - rect.top),
                             (end[0] - rect.left, end[1] - rect.top), 1)
        _GEO_CACHE["surface"] = (key, surface)
        cached = _GEO_CACHE["surface"]
    display.blit(cached[1], rect.topleft)

    for ax, ay, bx, by, ssector, solid in segs:
        if ssector in walked:
            pygame.draw.line(display, DOCK_ACCENT if solid else (72, 138, 92),
                             to_screen(ax, ay), to_screen(bx, by), 2)

    if pose is not None:
        px, py = to_screen(pose[0], pose[1])
        # Clipped to the map area: unclipped it shot across the panel beside it
        # and read as two stray diagonals. Short enough to say "facing this
        # way" rather than drawing lines across the whole level.
        previous_clip = display.get_clip()
        display.set_clip(inner)
        reach = 0.22 * math.hypot(inner.width, inner.height)
        for edge in (-45.0, 45.0):
            angle = math.radians(pose[3] + edge)
            pygame.draw.line(display, (120, 96, 40), (px, py),
                             (px + math.cos(angle) * reach,
                              py - math.sin(angle) * reach), 1)
        display.set_clip(previous_clip)
        pygame.draw.circle(display, DOCK_HOT, (px, py), 4)

    display.blit(fonts["heading"].render("MAP, CULLED", True, DOCK_ACCENT),
                 (rect.left + 6, rect.top + 4))
    total = len({s[4] for s in segs})
    options = [f"{len(walked)} of {total} subsectors drawn"]
    if stats and stats.get("bsp_children"):
        options.insert(0, f"{len(walked)}/{total} subsectors, "
                          f"{stats['bsp_kept']}/{stats['bsp_children']} "
                          f"branches kept")
    # Longest form that still clears the title, rather than sliding back over
    # it when it does not fit.
    left = rect.left + 12 + fonts["heading"].size("MAP, CULLED")[0]
    for text_value in options:
        label = fonts["small"].render(text_value, True, DOCK_DIM)
        if left + label.get_width() <= rect.right - 6:
            display.blit(label, (left, rect.top + 6))
            break


# The renderer's real dataflow: id, label, stat key, column, slot, colour. Read
# left to right this is the shape of a frame -- a BSP walk narrowing to a
# handful of subsectors, four surface kinds fanning out into tens of thousands
# of candidate pixels, then a collapse to exactly one row per pixel.
# The gameplay tic, as doom_run_game_tic actually runs it. Unlike the render
# query -- one straight-line statement -- the tic is a CONDITIONALLY BRANCHING 
TIC_GROUP_COLOURS = {
    "always": (117, 211, 139),
    "world":  (79, 126, 168),
    "player": (235, 178, 58),
    "combat": (224, 96, 58),
}
# A stage that fires for one tic is lit for 28 ms -- invisible at 60 fps. Hold
# it and fade, so a single hitscan still reads as a flash. Measured: firing the
# pistol lights `fire`+`damage` on exactly one tic in fourteen.
TIC_STAGE_FADE = 0.55


def draw_tic_rack(display, rect, fired_at, now, fonts, tic_ms=None):
    """The gameplay tic's stages, lit as they fire.

    The render pipeline shows one query fanning out. This shows the other half
    of the demo -- the simulation, which is equally SQL and was previously
    represented by a single line graph. Press a key and a stage lights: use a
    door and use -> special -> doors runs; shoot and weapon -> fire -> damage.
    """
    display.fill(DOCK_BG, rect)
    display.blit(fonts["heading"].render("GAME TIC", True, DOCK_ACCENT),
                 (rect.left + 8, rect.top + 4))
    head = fonts["heading"].get_linesize() + 6
    budget_ms = doom_config.TIC_SECONDS * 1000.0
    caption = f"35 Hz, {budget_ms:.1f} ms budget"
    if tic_ms is not None:
        caption = f"{tic_ms:.1f} / {budget_ms:.1f} ms"
    label = fonts["small"].render(caption, True, DOCK_DIM)
    left = rect.left + 12 + fonts["heading"].size("GAME TIC")[0]
    if left + label.get_width() <= rect.right - 6:
        display.blit(label, (left, rect.top + 6))

    inner = pygame.Rect(rect.left + 12, rect.top + head,
                        rect.width - 24, rect.height - head - 8)
    groups = []
    for _bit, _name, group in TIC_STAGES:
        if group not in groups:
            groups.append(group)
    # One column per stage, with a gap between groups so the clusters read.
    gaps = len(groups) - 1
    cell_w = (inner.width - gaps * 14) / len(TIC_STAGES)
    cell_h = min(inner.height - fonts["small"].get_linesize() - 4,
                 max(16, inner.height * 0.55))
    x = inner.left
    previous = None
    for bit, name, group in TIC_STAGES:
        if previous is not None and group != previous:
            x += 14
        previous = group
        base = TIC_GROUP_COLOURS[group]
        age = now - fired_at.get(bit, -99.0)
        if age < 0.0 or age > TIC_STAGE_FADE:
            level = 0.0
        else:
            level = 1.0 - age / TIC_STAGE_FADE
        cell = pygame.Rect(round(x), inner.top, max(2, round(cell_w) - 2),
                           round(cell_h))
        # Dark seat always visible, so the rack reads as a fixed set of stages
        # rather than appearing and vanishing.
        pygame.draw.rect(display, tuple(round(c * 0.16) for c in base), cell)
        if level > 0.0:
            lit = tuple(round(c * (0.30 + 0.70 * level)) for c in base)
            pygame.draw.rect(display, lit, cell)
        pygame.draw.rect(display, tuple(round(c * 0.45) for c in base), cell, 1)
        text = fonts["small"].render(
            name, True, DOCK_INK if level > 0.35 else DOCK_DIM)
        # At small window scales a cell is narrower than its own name, and
        # unclipped labels ran into their neighbours ("sound"+"monsters" read
        # as one word). Clip each to its cell: a truncated name still says
        # which stage it is, an overlapping one does not.
        label_clip = display.get_clip()
        display.set_clip(pygame.Rect(cell.left - 1, cell.bottom,
                                     cell.width + 2, text.get_height() + 4))
        # Centre it when it fits; when it does not, left-align so the clip
        # takes the tail ("monst") instead of both ends ("onste").
        text_x = (cell.left if text.get_width() > cell.width
                  else cell.centerx - text.get_width() / 2)
        display.blit(text, (text_x, cell.bottom + 2))
        display.set_clip(label_clip)
        x += cell_w


PIPELINE_NODES = (
    # The whole frame is a pure function of four numbers -- $4..$7, one row of
    # `pos`. Everything to the right of this node is fan-out from it, which is
    # the single fact the diagram exists to make visible.
    ("cam", "camera", 1, 0, 0, (235, 220, 140)),
    # Culling, where it belongs: the frustum test is the first thing the query
    # does and the only step near the top that SHRINKS. Showing bsp walk alone
    # showed the survivors with no sign that 476 children were tested.
    ("frustum", "nodes tested", "bsp_children", 1, 0, (117, 211, 139)),
    ("bsp", "bsp walk", "subsectors", 2, 0, (117, 211, 139)),
    # Sprites branch from the camera, NOT from the BSP walk -- see the comment
    # in render_stats_tail.sql. Drawing them out of `bsp` would be a lie.
    ("things", "things", "things_in_view", 1, 1, (111, 191, 122)),
    ("onscreen", "on screen", "things_drawn", 2, 1, (111, 191, 122)),
    ("segs", "segs", "segs", 3, 0, (117, 211, 139)),
    ("spans", "wall spans", "wall_spans", 4, 0, (117, 211, 139)),
    ("wall", "wall", "wall_px", 5, 0, (224, 145, 58)),
    ("plane", "plane", "plane_px", 5, 1, (79, 126, 168)),
    ("sprite", "sprites", "sprite_px", 5, 2, (111, 191, 122)),
    ("ranked", "candidates", "fragments_ranked", 6, 0, (235, 178, 58)),
    ("resolve", "one per pixel", "pixels_resolved", 7, 0, (235, 178, 58)),
    # The weapon never enters the depth ranking. psprite_resolved picks its own
    # winner by layer and final_pixels FULL JOINs it OVER the resolved view, so
    # it wins every pixel it covers -- which is exactly R_DrawPlayerSprites,
    # drawn after R_DrawMasked with no depth test. Feeding it into "candidates"
    # would draw a dataflow the query does not have.
    ("weapon", "weapon", "psprite_px", 7, 1, (143, 123, 196)),
    ("ui", "status bar", "ui_px", 7, 2, (150, 145, 128)),
    ("frame", "framebuffer", None, 8, 0, (235, 220, 140)),
)
PIPELINE_EDGES = (
    ("cam", "frustum"), ("cam", "things"),
    ("frustum", "bsp"), ("bsp", "segs"),
    ("things", "onscreen"), ("onscreen", "sprite"),
    ("segs", "spans"), ("spans", "wall"), ("spans", "plane"),
    ("wall", "ranked"), ("plane", "ranked"), ("sprite", "ranked"),
    ("ranked", "resolve"), ("resolve", "frame"), ("weapon", "frame"),
    ("ui", "frame"),
)


def draw_pipeline_graph(display, rect, stats, fonts):
    """The renderer's stages as a flow, each pipe carrying its own rows.

    Sits between the other two views: the operator tree shows all 444 steps and
    the bars show quantities, but neither shows that this is a dataflow with a
    fan-out and a merge in it. Pipe thickness is log-scaled -- the stages span
    three orders of magnitude and linear would make the BSP walk invisible --
    but where several pipes meet a node they split its port in true proportion,
    so the fan-out and the collapse are honest.
    """
    display.fill(DOCK_BG, rect)
    head = fonts["heading"].get_linesize() + 6
    display.blit(fonts["heading"].render("RENDER PIPELINE", True, DOCK_ACCENT),
                 (rect.left + 8, rect.top + 4))
    if stats is None:
        return

    def node_rows(key):
        if key is None:                 # framebuffer: the view plus status bar
            return stats["view_px"] + stats["ui_px"]
        if isinstance(key, int):        # a literal, for the one-row camera
            return key
        return stats[key]

    counts = {node[0]: node_rows(node[2]) for node in PIPELINE_NODES}
    peak = max(counts.values()) or 1
    log_peak = math.log10(1 + peak)

    def port(rows):
        return 4.0 + 46.0 * math.log10(1 + rows) / log_peak

    columns = max(node[3] for node in PIPELINE_NODES)
    inner = pygame.Rect(rect.left + 14, rect.top + head,
                        rect.width - 28, rect.height - head - 10)
    col_step = inner.width / (columns + 1)
    box_w = min(col_step * 0.52, 150)
    place = {}
    for node_id, label, _key, col, slot, colour in PIPELINE_NODES:
        slots = sum(1 for n in PIPELINE_NODES if n[3] == col)
        band_h = inner.height / slots
        place[node_id] = {"x": inner.left + col * col_step + box_w / 2,
                          "y": inner.top + band_h * (slot + 0.5),
                          "h": port(counts[node_id]), "label": label,
                          "colour": colour, "rows": counts[node_id]}

    # Split each node's port between the edges meeting it, in true proportion.
    offsets = {}
    for side, index in (("in", 1), ("out", 0)):
        for node_id in place:
            edges = [e for e in PIPELINE_EDGES if e[index] == node_id]
            total = sum(counts[e[1 - index]] for e in edges) or 1
            cursor = -place[node_id]["h"] / 2.0
            for edge in edges:
                share = place[node_id]["h"] * counts[edge[1 - index]] / total
                offsets[(side, edge)] = (cursor, cursor + share)
                cursor += share

    for source, target in PIPELINE_EDGES:
        a, b = place[source], place[target]
        a0, a1 = offsets[("out", (source, target))]
        b0, b1 = offsets[("in", (source, target))]
        pygame.draw.polygon(
            display, tuple(round(c * 0.55) for c in a["colour"]),
            [(a["x"] + box_w / 2, a["y"] + a0),
             (b["x"] - box_w / 2, b["y"] + b0),
             (b["x"] - box_w / 2, b["y"] + b1),
             (a["x"] + box_w / 2, a["y"] + a1)])

    for node in place.values():
        box = pygame.Rect(0, 0, box_w, max(18, node["h"]))
        box.center = (node["x"], node["y"])
        pygame.draw.rect(display, DOCK_BG, box)
        pygame.draw.rect(display, node["colour"], box, 2)
        label = fonts["small"].render(node["label"], True, DOCK_DIM)
        # Clipped to the column pitch for the same reason as the tic rack's:
        # at small scales "nodes tested" and "bsp walk" overlapped each other.
        node_clip = display.get_clip()
        display.set_clip(pygame.Rect(round(node["x"] - col_step / 2),
                                     round(box.top - label.get_height() - 3),
                                     round(col_step), label.get_height() + 3))
        label_x = (node["x"] - col_step / 2
                   if label.get_width() > col_step
                   else node["x"] - label.get_width() / 2)
        display.blit(label, (label_x, box.top - label.get_height() - 2))
        display.set_clip(node_clip)
        value = fonts["small"].render(f"{node['rows']:,}", True, DOCK_INK)
        display.blit(value, (node["x"] - value.get_width() / 2,
                             node["y"] - value.get_height() / 2))


def draw_sql_dock(display, game_width, scale, fonts, stats, stats_seconds,
                  sql_fps, render_ms, now=0.0, fps_samples=(), plan=None,
                  tic_ms=None, tic_samples=()):
    """Draw the permanent SQL panel in the strip beside the game.

    This is the whole point of the demo, so it is not behind a key: without it
    on screen the window is just Doom, and the interesting part -- that a
    database is doing this, tens of thousands of rows at a time, tens of times
    a second -- is invisible.

    The panel is cached and repainted only when a number it shows changes. The
    display loop runs several times faster than the figures do, and laying out
    this much text every frame cost more than the frame it sits next to.
    """
    dock = pygame.Rect(game_width, 0, display.get_width() - game_width,
                       display.get_height())
    if dock.width <= 0:
        return dock, None

    recent_fps = [sample for sample in fps_samples if sample[0] >= now - 30.0]
    key = (
        dock.size, round(sql_fps, 1), round(render_ms, 1),
        None if stats is None else tuple(sorted(stats.items())),
        round(stats_seconds, 3),
        None if tic_ms is None else round(tic_ms, 1),
        # Tic samples arrive ~35x a second; bucket them so the panel repaints a
        # few times a second rather than on every one.
        len(tic_samples) // 8,
        len(recent_fps), round(recent_fps[-1][1], 1) if recent_fps else None,
        None if plan is None else (id(plan), len(plan[0])),
    )
    cached_key, cached = _DOCK_CACHE.get("panel", (None, None))
    if cached_key == key:
        display.blit(cached, dock.topleft)
        return dock, _DOCK_CACHE.get("plan_rect")

    panel = pygame.Surface(dock.size)
    panel.fill(DOCK_BG)
    pygame.draw.line(panel, DOCK_HOT, (0, 0), (0, dock.height), 2)

    pad = max(4, DOCK_PAD_DOOM * scale)
    x = pad
    inner = dock.width - pad * 2
    y = pad

    def text(surface_font, value, color, dx=0):
        nonlocal y
        panel.blit(surface_font.render(value, True, color), (x + dx, y))
        y += surface_font.get_linesize()

    def rule(gap=10):
        nonlocal y
        y += gap
        pygame.draw.line(panel, (55, 62, 52), (x, y), (x + inner, y), 1)
        y += gap

    def row(label, value, color=DOCK_INK):
        nonlocal y
        font = fonts["row"]
        panel.blit(font.render(label, True, DOCK_DIM), (x, y))
        value_surface = font.render(value, True, color)
        panel.blit(value_surface, (x + inner - value_surface.get_width(), y))
        y += font.get_linesize()

    if plan is not None:
        # Every operator's measured output summed across the plan: the rows the
        # query actually moves, not the rows it finally returns. The fragment
        # count this used to show is one stage of that, and it lives in the
        # funnel below where the bars explain it.
        plan_rows = sum(node["rows"] for node in plan[0])
        rate = plan_rows * sql_fps / 1e6
        hero = fonts["hero"].render(
            f"{rate:.0f}M" if rate >= 10 else f"{rate:.1f}M", True, DOCK_HOT)
        panel.blit(hero, (x, y))
        y += fonts["hero"].get_linesize()
        text(fonts["caption"], "rows / second through the query", DOCK_DIM)
        rule()

    # The funnel that used to stand here -- three traversal bars, a stacked
    # source bar and the collapse ratio -- is now the flow diagram in the band,
    # where the fan-out and the collapse are shapes instead of numbers. Only
    # the alarm survives: uncovered pixels have no node in that diagram, and a
    # non-zero count means the frame is wrong rather than merely slow.
    if stats is not None and stats["holes"]:
        text(fonts["heading"], "UNCOVERED PIXELS", DOCK_HOT)
        row("this frame", f"{stats['holes']:,}", DOCK_HOT)
        rule()

    # Two histories now, one per loop, each headed by its own current value
    # so no number needs stating twice.
    leftover = dock.height - pad - y
    heading_h = fonts["heading"].get_linesize()

    # The silhouette is reserved first and generously: it is the only thing in
    # the panel that shows how large the query actually is, which is the point
    # the demo makes. 444 operators squeezed into a couple of hundred pixels is
    # a smear, not a picture.
    plan_block = 0
    plan_height = 0
    if plan is not None:
        spare = leftover - heading_h - 6
        if spare >= 150:
            plan_height = min(round(leftover * 0.62), spare)
            plan_block = heading_h + plan_height + 6

    def draw_history(title, current, samples, value_index, floor_max,
                     budget=None):
        """One headed sparkline over the trailing 30 seconds."""
        nonlocal y
        panel.blit(fonts["heading"].render(title, True, DOCK_ACCENT), (x, y))
        value = fonts["heading"].render(current, True, DOCK_HOT)
        panel.blit(value, (x + inner - value.get_width(), y))
        y += heading_h
        graph = pygame.Rect(x, y, inner, graph_height)
        pygame.draw.rect(panel, (3, 5, 4), graph)
        recent = [sample for sample in samples if sample[0] >= now - 30.0]
        # Scaled to the 98th percentile, not the maximum. One outlier -- a
        # replan stall, a frame that walked over a corpse -- is enough to put
        # the axis an order of magnitude above everything else and squash 30
        # seconds of real signal, and the budget line with it, onto the floor.
        # Samples are clipped to y_max when plotted, so an outlier still shows:
        # it just tops out at the ceiling instead of redrawing the whole chart
        # around itself. With only a handful of samples this IS the maximum.
        ordered = sorted(sample[value_index] for sample in recent)
        peak = (ordered[min(len(ordered) - 1, int(len(ordered) * 0.98))]
                if ordered else 0.0)
        y_max = max(floor_max, peak * 1.25)
        for fraction in (0.0, 0.5, 1.0):
            gy = round(graph.bottom - 1 - fraction * (graph.height - 1))
            pygame.draw.line(panel, (35, 43, 36),
                             (graph.left, gy), (graph.right - 1, gy), 1)
        if len(recent) >= 2:
            points = [
                (graph.left + round((sample[0] - (now - 30.0)) / 30.0
                                    * (graph.width - 1)),
                 graph.bottom - 1 - round(min(sample[value_index], y_max)
                                          / y_max * (graph.height - 1)))
                for sample in recent
            ]
            pygame.draw.lines(panel, DOCK_ACCENT, False, points,
                              max(1, scale // 3))
        # Without a marked budget the tic number says nothing: 3 ms is only
        # impressive against the 28.6 ms a 35 Hz tic is allowed to take.
        if budget is not None and budget <= y_max:
            by = round(graph.bottom - 1 - budget / y_max * (graph.height - 1))
            for dash in range(graph.left, graph.right - 1, 6):
                pygame.draw.line(panel, DOCK_HOT, (dash, by),
                                 (min(dash + 3, graph.right - 2), by), 1)
            tag = fonts["small"].render("35 Hz budget", True, DOCK_HOT)
            panel.blit(tag, (graph.right - tag.get_width() - 4,
                             max(graph.top + 2, by - tag.get_height() - 1)))
        panel.blit(fonts["small"].render(f"{y_max:.0f}", True, DOCK_DIM),
                   (graph.left + 4, graph.top + 2))
        y = graph.bottom + pad

    graphs = 2
    graph_room = leftover - plan_block - graphs * (heading_h + pad)
    graph_height = max(0, min(round(graph_room / graphs), round(leftover * 0.2)))
    if graph_height < 34:
        graph_height = 0
    if graph_height:
        draw_history("SQL FRAMES / S", f"{sql_fps:.0f}", fps_samples, 1, 10.0)
        draw_history("GAMEPLAY TIC / MS",
                     "-" if tic_ms is None else f"{tic_ms:.1f}",
                     tic_samples, 1, doom_config.TIC_SECONDS * 1000.0,
                     budget=doom_config.TIC_SECONDS * 1000.0)

    plan_rect = None
    if plan_height:
        y = dock.height - pad - plan_height
        node_count = len(plan[0])
        deep = max(n["depth"] for n in plan[0]) + 1
        panel.blit(
            fonts["small"].render(
                f"render query (operators: {node_count}, "
                f"pipeline depth: {deep})", True, DOCK_DIM),
            (x, y - heading_h))
        plan_rect = pygame.Rect(dock.left + x, y, inner, plan_height)

    _DOCK_CACHE["panel"] = (key, panel)
    _DOCK_CACHE["plan_rect"] = plan_rect
    display.blit(panel, dock.topleft)
    return dock, plan_rect


class StatsWorker:
    """Sample the renderer's own row counts on its own connection.

    The counting query runs the whole render pipeline, so it costs about what a
    frame costs. Sampling it a couple of times a second keeps the overlay live
    without competing with the render or gameplay loops for the server.
    """

    # World counts are cheap (~3 ms) so they sample often enough to look live;
    # the render counting pass costs a whole frame, so it goes slower.
    INTERVAL = 0.2
    RENDER_EVERY = 3
    # The plan costs a whole EXPLAIN (ANALYZE) pass -- about four frames -- and
    # its shape never changes, so it is sampled rarely. Only the cardinalities
    # and the execution timeline move, and those look live at this rate because
    # the panel replays the timeline continuously between samples.
    PLAN_EVERY = 25

    def __init__(self, map_id, player_thing_id, skill):
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._context = (map_id, player_thing_id, skill)
        self._pose = None
        self._stats = None
        self._seconds = 0.0
        self._plan = None
        self._thread = threading.Thread(
            target=self._run, name="sql-render-stats", daemon=True,
        )
        self._thread.start()

    def request(self, pose, map_id=None, player_thing_id=None, skill=None):
        """Set the pose to count next, or None to stop sampling."""
        with self._lock:
            self._pose = pose
            old_map, old_player, old_skill = self._context
            self._context = (
                old_map if map_id is None else map_id,
                old_player if player_thing_id is None else player_thing_id,
                old_skill if skill is None else skill,
            )

    def poll(self):
        with self._lock:
            return self._stats, self._seconds

    def poll_plan(self):
        with self._lock:
            return self._plan

    def close(self):
        self._stop.set()
        self._thread.join(timeout=0.5)

    def _run(self):
        conn = None
        cur = None
        try:
            conn = psycopg2.connect(DB_DSN)
            conn.autocommit = True
            cur = conn.cursor()
            tune_replanning(cur)
            load_constants(cur)
            sql.prepare_render_stats(cur)
            ticks = 0
            plan_failed = False
            while not self._stop.wait(self.INTERVAL):
                with self._lock:
                    pose = self._pose
                    context = self._context
                if pose is None:
                    continue
                ticks += 1
                try:
                    stats = None
                    started = time.perf_counter()
                    if ticks % self.RENDER_EVERY == 0:
                        stats = sql.fetch_render_stats(cur, *context, pose)
                    elapsed = time.perf_counter() - started
                except Exception:
                    # Diagnostics must never take the game down with them.
                    continue
                if stats is not None:
                    with self._lock:
                        self._stats = stats
                        self._seconds = elapsed
                if ticks % self.PLAN_EVERY == 1 and not plan_failed:
                    try:
                        plan = sql.fetch_plan_graph(cur, *context, pose)
                        with self._lock:
                            self._plan = plan
                    except Exception:
                        # One failure is enough: stop paying for it every time.
                        plan_failed = True
        except Exception:
            pass
        finally:
            if cur is not None:
                cur.close()
            if conn is not None:
                conn.close()


def reset_fps_badge():
    """Forget the cached badge surface (window scale changed)."""
    _FPS_BADGE["text"] = None


def invalidate_geometry():
    """Forget the cull view's cached map projection (level or window changed)."""
    _GEO_CACHE.clear()
