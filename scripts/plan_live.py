#!/usr/bin/env python3
"""Live view of the renderer statement's query plan, in its own window.

Runs EXPLAIN (ANALYZE, FORMAT JSON) on sql/renderer.sql against the pose the
player is actually standing at, once a second, and animates the result: node
size is the rows that operator really produced, node colour is its share of the
frame's time, and dots flow along each edge at a rate set by the rows crossing
it. Turn around in the game and the plan visibly changes shape.

Deliberately a separate process from doom_client: the counting pass costs about
a frame, and nothing here may ever cost the game a frame. Run it on the second
monitor.
"""
import argparse
import json
import math
import sys
import threading
import time
from pathlib import Path

import psycopg2
import pygame

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import doom_sql as sql  # noqa: E402

BG = (10, 11, 9)
INK = (215, 211, 194)
DIM = (125, 122, 108)
ACCENT = (117, 211, 139)
HOT = (235, 178, 58)

# Children hang off these keys, sometimes behind a wrapper (a set operation's
# arguments are {columns, input} pairs), so the walk looks for the nearest
# operator nodes rather than assuming a fixed shape.
CHILD_KEYS = ("input", "left", "right", "magic", "pipelineBreaker", "arguments")

OPERATOR_COLOURS = {
    "join": (224, 145, 58), "pipelinebreakerscan": (79, 126, 168),
    "tablescan": (111, 191, 122), "select": (192, 91, 107),
    "map": (143, 123, 196), "groupby": (216, 195, 74),
    "temp": (90, 168, 160), "generateseries": (155, 162, 79),
    "setoperation": (199, 123, 176), "sort": (122, 139, 160),
    "inlinetable": (160, 139, 111), "window": (95, 158, 196),
    "earlyprobe": (138, 143, 116), "assertsinglerow": (156, 111, 138),
}
DEFAULT_COLOUR = (123, 128, 121)


def child_operators(node):
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

    for key in CHILD_KEYS:
        if key in node:
            descend(node[key])
    return found


def parse(payload):
    """-> (nodes, edges, signature, per-operator rows and microseconds)."""
    plan = payload["plan"]
    nodes, edges = [], []

    def walk(raw, depth, parent):
        index = len(nodes)
        rows = raw.get("analyzePlanCardinality")
        if rows is None:
            rows = raw.get("cardinality") or 0
        nodes.append({
            "op": raw.get("operator", "?"),
            "analyze_id": raw.get("analyzePlanId"),
            "depth": depth,
            "rows": int(rows),
            "micros": 0.0,
            "children": [],
        })
        if parent is not None:
            nodes[parent]["children"].append(index)
            edges.append((parent, index))
        for child in child_operators(raw):
            walk(child, depth + 1, index)

    walk(plan, 0, None)

    # Pipeline durations are the only timing the plan carries. Charge each
    # pipeline's full time to every operator in it, rather than splitting it:
    # the question the picture answers is "which operators are on the paths the
    # frame's time went into", and dividing by member count flattened every
    # operator to a fraction of a millisecond and hid the hot paths entirely.
    by_analyze = {}
    for index, node in enumerate(nodes):
        if node["analyze_id"] is not None:
            by_analyze.setdefault(node["analyze_id"], []).append(index)
    for pipeline in payload.get("analyzePlanPipelines", ()):
        duration = pipeline.get("duration", 0)
        for op in pipeline.get("operators", ()):
            for index in by_analyze.get(op, ()):
                nodes[index]["micros"] += duration

    signature = (len(nodes), tuple(n["op"] for n in nodes))
    return nodes, edges, signature


def layout(nodes, width, height, margin_left, margin_top):
    """Tidy tree: depth left to right, one row per leaf, then fit to window."""
    cursor = [0]

    def place(index):
        node = nodes[index]
        if node["children"]:
            for child in node["children"]:
                place(child)
            first = nodes[node["children"][0]]
            last = nodes[node["children"][-1]]
            node["ry"] = (first["ry"] + last["ry"]) / 2.0
        else:
            node["ry"] = cursor[0]
            cursor[0] += 1
        node["rx"] = node["depth"]

    place(0)
    rows = max(1, cursor[0] - 1)
    depth = max(1, max(n["depth"] for n in nodes))
    span_x = max(60, width - margin_left - 30)
    span_y = max(60, height - margin_top - 24)
    for node in nodes:
        node["x"] = margin_left + node["rx"] / depth * span_x
        node["y"] = margin_top + node["ry"] / rows * span_y


class Poller(threading.Thread):
    """Re-explain the renderer at the player's live pose, on its own connection."""

    def __init__(self, dsn, map_id, player, skill, interval):
        super().__init__(daemon=True)
        self.dsn, self.map_id = dsn, map_id
        self.player, self.skill = player, skill
        self.interval = interval
        self.lock = threading.Lock()
        self.latest = None
        self.error = None
        self.samples = 0
        self.seconds = 0.0
        self.stop = threading.Event()

    def _pose(self, cur):
        cur.execute(
            "SELECT position_x, position_y, view_z, view_angle FROM player_state "
            "WHERE map_id = %s AND player_thing_id = %s",
            (self.map_id, self.player),
        )
        row = cur.fetchone()
        return tuple(float(v) for v in row) if row else None

    def run(self):
        try:
            conn = psycopg2.connect(self.dsn)
            conn.autocommit = True
            cur = conn.cursor()
            body = sql.load_sql("renderer.sql").rstrip().rstrip(";")
            while not self.stop.is_set():
                started = time.perf_counter()
                try:
                    pose = self._pose(cur)
                    if pose is None:
                        raise RuntimeError("no player_state row")
                    query = body
                    for token, value in (
                        ("$1", str(self.map_id)), ("$2", str(self.player)),
                        ("$3", str(self.skill)), ("$4", repr(pose[0])),
                        ("$5", repr(pose[1])), ("$6", repr(pose[2])),
                        ("$7", repr(pose[3])),
                    ):
                        query = query.replace(token, value)
                    cur.execute("EXPLAIN (ANALYZE, FORMAT JSON) " + query)
                    payload = json.loads(cur.fetchone()[0])
                    with self.lock:
                        self.latest = parse(payload)
                        self.error = None
                        self.samples += 1
                        self.seconds = time.perf_counter() - started
                except Exception as exc:
                    with self.lock:
                        self.error = str(exc).splitlines()[0][:90]
                self.stop.wait(self.interval)
        except Exception as exc:
            with self.lock:
                self.error = str(exc).splitlines()[0][:90]

    def take(self):
        with self.lock:
            return self.latest, self.error, self.samples, self.seconds


def heat(share):
    """Time share -> colour ramp: cool grey, through amber, to hot."""
    share = max(0.0, min(1.0, share))
    stops = ((0.0, (46, 52, 44)), (0.35, (95, 158, 196)),
             (0.7, (235, 178, 58)), (1.0, (240, 90, 70)))
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if share <= b:
            t = 0.0 if b == a else (share - a) / (b - a)
            return tuple(round(ca[i] + (cb[i] - ca[i]) * t) for i in range(3))
    return stops[-1][1]


def paint_static(surface, nodes, edges, fonts, stats):
    """Everything that only changes when a new plan sample arrives."""
    surface.fill(BG)
    peak_rows = max((n["rows"] for n in nodes), default=1) or 1
    peak_time = max((n["micros"] for n in nodes), default=1.0) or 1.0
    log_peak = math.log10(1 + peak_rows)

    def weight(rows):
        return 1.0 + 4.0 * math.log10(1 + rows) / log_peak

    def radius(rows):
        return 2.0 + 8.0 * math.log10(1 + rows) / log_peak

    for parent, child in edges:
        a, b = nodes[parent], nodes[child]
        colour = OPERATOR_COLOURS.get(b["op"], DEFAULT_COLOUR)
        faded = tuple(round(c * 0.45) for c in colour)
        pygame.draw.line(surface, faded, (a["x"], a["y"]), (b["x"], b["y"]),
                         max(1, round(weight(b["rows"]))))
    for node in nodes:
        r = radius(node["rows"])
        pygame.draw.circle(surface, heat(node["micros"] / peak_time),
                           (node["x"], node["y"]), r)
        # The kind-coloured ring only helps once there is a node big enough to
        # put it on; on a 3px dot it swamps the heat colour underneath.
        if r >= 5.0:
            pygame.draw.circle(
                surface, OPERATOR_COLOURS.get(node["op"], DEFAULT_COLOUR),
                (node["x"], node["y"]), r, 2)

    # Name the operators that dominated either dimension.
    labelled, placed = [], []
    for node in sorted(nodes, key=lambda n: -(n["micros"] * 1e6 + n["rows"])):
        if len(labelled) >= 10:
            break
        if all(abs(node["y"] - other["y"]) > fonts["label"].get_linesize()
               or abs(node["x"] - other["x"]) > 240 for other in placed):
            labelled.append(node)
            placed.append(node)
    for node in labelled:
        text = (f'{node["op"]}  {node["rows"]:,}'
                f'  {node["micros"] / 1000.0:.1f}ms')
        surface.blit(fonts["label"].render(text, True, INK),
                     (node["x"] + radius(node["rows"]) + 6, node["y"] - 8))

    y = 16
    surface.blit(fonts["title"].render("RENDERER QUERY PLAN, LIVE", True, ACCENT),
                 (20, y))
    y += fonts["title"].get_linesize() + 2
    for line in stats:
        surface.blit(fonts["stat"].render(line, True, DIM), (20, y))
        y += fonts["stat"].get_linesize()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--map", type=int, default=1)
    ap.add_argument("--player", type=int, default=0)
    ap.add_argument("--skill", type=int, default=2)
    ap.add_argument("--interval", type=float, default=1.0,
                    help="seconds between EXPLAIN samples (default 1.0)")
    ap.add_argument("--width", type=int, default=1600)
    ap.add_argument("--height", type=int, default=900)
    args = ap.parse_args()

    poller = Poller(args.dsn, args.map, args.player, args.skill, args.interval)
    poller.start()

    pygame.init()
    pygame.display.set_caption("SQL Doom - live query plan")
    screen = pygame.display.set_mode((args.width, args.height),
                                     pygame.RESIZABLE)
    fonts = {
        "title": pygame.font.Font(None, 34),
        "stat": pygame.font.Font(None, 22),
        "label": pygame.font.Font(None, 19),
    }
    clock = pygame.time.Clock()

    static = None
    nodes = edges = None
    signature = None
    seen = -1
    flow = []

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN and event.key in (
                    pygame.K_ESCAPE, pygame.K_q):
                running = False
            elif event.type == pygame.VIDEORESIZE:
                screen = pygame.display.set_mode((event.w, event.h),
                                                 pygame.RESIZABLE)
                signature = None  # force a re-layout at the new size

        latest, error, samples, seconds = poller.take()
        if latest is not None and (samples != seen or signature != latest[2]):
            nodes, edges, signature = latest
            seen = samples
            layout(nodes, screen.get_width(), screen.get_height(),
                   margin_left=320, margin_top=150)
            total_rows = sum(n["rows"] for n in nodes)
            hottest = max(nodes, key=lambda n: n["micros"])
            stats = [
                f"{len(nodes)} operators, {max(n['depth'] for n in nodes) + 1} "
                f"deep, {len(set(n['op'] for n in nodes))} kinds",
                f"{total_rows:,} rows through the plan, this frame",
                f"hottest path: {hottest['op']}, "
                f"{hottest['micros'] / 1000.0:.1f} ms of pipeline time",
                "node size = rows produced, colour = time on its pipelines",
                f"EXPLAIN (ANALYZE) every {args.interval:g}s, "
                f"{seconds * 1000:.0f} ms per pass",
            ]
            static = pygame.Surface(screen.get_size())
            paint_static(static, nodes, edges, fonts, stats)
            # One dot per edge that actually carries rows, phase-staggered.
            peak = max((n["rows"] for n in nodes), default=1) or 1
            flow = []
            for parent, child in edges:
                rows = nodes[child]["rows"]
                if rows < peak * 0.002:
                    continue
                speed = 0.15 + 0.85 * math.log10(1 + rows) / math.log10(1 + peak)
                flow.append((parent, child, speed,
                             (parent * 7 + child * 13) % 100 / 100.0))

        if static is None:
            screen.fill(BG)
            message = error or "waiting for the first plan..."
            screen.blit(fonts["title"].render(message, True,
                                              HOT if error else DIM), (20, 20))
        else:
            screen.blit(static, (0, 0))
            now = time.perf_counter()
            for parent, child, speed, phase in flow:
                a, b = nodes[parent], nodes[child]
                t = (now * speed * 0.5 + phase) % 1.0
                pygame.draw.circle(
                    screen, ACCENT,
                    (round(a["x"] + (b["x"] - a["x"]) * (1.0 - t)),
                     round(a["y"] + (b["y"] - a["y"]) * (1.0 - t))), 2)
            if error:
                screen.blit(fonts["stat"].render(f"stale: {error}", True, HOT),
                            (20, screen.get_height() - 26))
        pygame.display.flip()
        clock.tick(60)

    poller.stop.set()
    pygame.quit()


if __name__ == "__main__":
    main()
