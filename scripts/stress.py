#!/usr/bin/env python3
"""Drive every SQL subsystem in turn and time each one.

The point is coverage plus attribution. Each phase sets up a situation that
forces one part of the pipeline to do real work, runs a fixed number of 35 Hz
tics through the same prepared statement the client uses, and renders frames
from the pose it ends in. Because doom_run_game_tic reports which stages it
actually executed (see tic_trace / dock.TIC_STAGES), the harness can
prove a phase exercised what it claims rather than taking it on trust, and
list any stage no phase ever reached.

Nothing here is hardcoded to a level's geometry: the features are discovered
by querying the map, so it runs against any loaded map.
"""

import argparse
import json
from pathlib import Path
import re
import statistics
import sys
import time

import psycopg2

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from doom_config import TIC_STAGES
import doom_sql as sql  # noqa: E402
from dock import TIC_STAGES  # noqa: E402

# (skill, move_fwd, move_strafe, running, turn_degrees, attack, weapon, use)
IDLE = (0.0, 0.0, False, 0.0, False, 0, False)
WALK = (1.0, 0.0, False, 0.0, False, 0, False)
RUN = (1.0, 0.0, True, 0.0, False, 0, False)
TURN = (0.0, 0.0, False, 8.0, False, 0, False)
FIRE = (0.0, 0.0, False, 0.0, True, 0, False)
USE = (0.0, 0.0, False, 0.0, False, 0, True)
WALK_FIRE = (0.6, 0.0, True, 4.0, True, 0, False)
# Everything a tic can be asked to do at once: move, strafe, turn, shoot and
# press use. Not quite everything it CAN do -- doom_cs_movement_mode picks the
# cheap 'turn' path only when the player is not moving at all, so the turn
# stage and the move stage are mutually exclusive by construction.
WORST = (1.0, 0.6, True, 6.0, True, 0, True)

# What a stage needs to exist on the map before it can possibly fire.
STAGE_NEEDS = {
    "scrollers": ("scrolling-texture lines",
                  "SELECT count(*) FROM linedefs WHERE map_id=%s "
                  "AND special IN (48,85)"),
    "use": ("usable lines",
            "SELECT count(*) FROM linedefs WHERE map_id=%s AND special <> 0"),
    "missiles": ("projectile-throwing monsters",
                 "SELECT count(*) FROM things WHERE map_id=%s "
                 "AND type IN (3001,3002,3003,3005,3006,16,71,64,66,67,68,69)"),
}

SECTOR_AT = """
WITH RECURSIVE bsp AS (
  (SELECT 1 AS d, n.id AS node_id, NULL::int AS ssec FROM nodes n
   WHERE n.map_id=%(m)s ORDER BY n.id DESC LIMIT 1)
  UNION ALL
  SELECT w.d+1, CASE WHEN nc.child_kind='NODE' THEN nc.child_node_id END,
         CASE WHEN nc.child_kind='SSECTOR' THEN nc.child_ssector_id END
  FROM bsp w JOIN nodes n ON n.map_id=%(m)s AND n.id=w.node_id
  JOIN node_children nc ON nc.map_id=%(m)s AND nc.node_id=n.id AND nc.side=
    CASE WHEN (%(x)s-n.x)::bigint*n.dy::bigint
            -(%(y)s-n.y)::bigint*n.dx::bigint > 0 THEN 'R' ELSE 'L' END
  WHERE w.node_id IS NOT NULL)
SELECT s.id, s.floor_height FROM bsp b
JOIN ssectors sst ON sst.map_id=%(m)s AND sst.id=b.ssec
JOIN segs seg ON seg.map_id=%(m)s AND seg.id>=sst.first_seg_id
  AND seg.id<sst.first_seg_id+sst.seg_count
JOIN linedefs ld ON ld.map_id=%(m)s AND ld.id=seg.linedef_id
JOIN sidedefs sd ON sd.map_id=%(m)s
  AND sd.id=CASE WHEN seg.direction=0 THEN ld.right_sd_id ELSE ld.left_sd_id END
JOIN sectors s ON s.map_id=%(m)s AND s.id=sd.sector_id
WHERE b.ssec IS NOT NULL LIMIT 1"""


class Stress:
    def __init__(self, cur, map_id, player_id, skill):
        self.cur = cur
        self.map_id = map_id
        self.player_id = player_id
        self.skill = skill
        self.results = []
        self.stages_seen = 0

    # ---------- helpers ----------
    def sector_at(self, x, y):
        self.cur.execute(SECTOR_AT, dict(m=self.map_id, x=x, y=y))
        row = self.cur.fetchone()
        return (row[0], float(row[1])) if row else (None, None)

    def place(self, x, y, angle=0.0):
        """Put the player at a point, resolving its sector like a spawn does."""
        sector, floor = self.sector_at(x, y)
        if sector is None:
            return False
        eye = floor + 41.0
        self.cur.execute(
            """UPDATE player_state SET position_x=%s, position_y=%s,
                 previous_x=%s, previous_y=%s, base_z=%s, view_z=%s,
                 view_angle=%s, momentum_x=0, momentum_y=0, momentum_z=0,
                 bob_strength=0, sector_id=%s
               WHERE map_id=%s AND player_thing_id=%s""",
            (x, y, x, y, eye, eye, angle, sector, self.map_id, self.player_id))
        self.cur.execute(
            "UPDATE things SET x=%s, y=%s, z=%s, angle=%s WHERE map_id=%s AND id=%s",
            (x, y, eye, angle, self.map_id, self.player_id))
        return True

    def point_in_sector(self, sector_id, samples=20):
        """A point actually inside a sector, found by sampling its bbox."""
        self.cur.execute(
            """SELECT MIN(v.x), MAX(v.x), MIN(v.y), MAX(v.y)
               FROM linedefs ld
               JOIN sidedefs sd ON sd.map_id=ld.map_id
                 AND sd.id IN (ld.right_sd_id, ld.left_sd_id)
               JOIN vertexes v ON v.map_id=ld.map_id
                 AND v.id IN (ld.v1_id, ld.v2_id)
               WHERE ld.map_id=%s AND sd.sector_id=%s""",
            (self.map_id, sector_id))
        row = self.cur.fetchone()
        if row is None or row[0] is None:
            return None
        x0, x1, y0, y1 = [float(v) for v in row]
        for i in range(samples):
            for j in range(samples):
                x = x0 + (x1 - x0) * (i + 0.5) / samples
                y = y0 + (y1 - y0) * (j + 0.5) / samples
                if self.sector_at(x, y)[0] == sector_id:
                    return x, y
        return None

    def line_front(self, line_id, back=48.0):
        """A point in front of a linedef's right side, facing it."""
        self.cur.execute(
            """SELECT v1.x, v1.y, v2.x, v2.y FROM linedefs ld
               JOIN vertexes v1 ON v1.map_id=ld.map_id AND v1.id=ld.v1_id
               JOIN vertexes v2 ON v2.map_id=ld.map_id AND v2.id=ld.v2_id
               WHERE ld.map_id=%s AND ld.id=%s""", (self.map_id, line_id))
        row = self.cur.fetchone()
        if row is None:
            return None
        x1, y1, x2, y2 = [float(v) for v in row]
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        dx, dy = x2 - x1, y2 - y1
        length = max(1e-6, (dx * dx + dy * dy) ** 0.5)
        # the right side's normal, which is the side a switch is usable from
        nx, ny = dy / length, -dx / length
        import math
        for dist in (back, back * 2, back * 3):
            px, py = mx + nx * dist, my + ny * dist
            if self.sector_at(px, py)[0] is not None:
                return px, py, math.degrees(math.atan2(my - py, mx - px))
        return None

    # ---------- the measurement itself ----------
    def phase(self, name, command, tics=40, renders=5, warm=8):
        """Run tics with one command, then render, and record the timings."""
        cmd = (self.skill,) + command
        for _ in range(warm):
            sql.execute_game_tic(self.cur, self.map_id, self.player_id, cmd)
            sql.finish_game_tic(self.cur, self.map_id, self.player_id)
        tic_ms, stages = [], 0
        for _ in range(tics):
            started = time.perf_counter()
            sql.execute_game_tic(self.cur, self.map_id, self.player_id, cmd)
            snap = sql.finish_game_tic(self.cur, self.map_id, self.player_id)
            tic_ms.append((time.perf_counter() - started) * 1000.0)
            stages |= snap.get("tic_stages", 0)
        self.stages_seen |= stages
        self.cur.execute(
            """SELECT position_x, position_y, view_z, view_angle
               FROM player_state WHERE map_id=%s AND player_thing_id=%s""",
            (self.map_id, self.player_id))
        pose = tuple(float(v) for v in self.cur.fetchone())
        render_ms = []
        for _ in range(renders):
            started = time.perf_counter()
            sql.render_frame(self.cur, self.map_id, self.player_id,
                             self.skill, pose)
            render_ms.append((time.perf_counter() - started) * 1000.0)
        self.results.append({
            "phase": name, "tics": tics, "stages": stages,
            "tic_p50": statistics.median(tic_ms),
            "tic_p95": sorted(tic_ms)[int(len(tic_ms) * 0.95) - 1],
            "tic_max": max(tic_ms),
            "render_p50": statistics.median(render_ms) if render_ms else None,
        })
        return self.results[-1]

    def note(self, name, seconds, detail=""):
        self.results.append({"phase": name, "tics": 0, "stages": 0,
                             "tic_p50": seconds * 1000.0, "tic_p95": None,
                             "tic_max": None, "render_p50": None,
                             "detail": detail})


# Stage names come from doom_config.TIC_STAGES, the same table the dock draws
# from, so there is no second list to drift. A line may set several bits at
# once -- doom_tic_secrets sets secrets, walkover and pickups together -- and
# those are ONE timed block, so the label joins their names.
def _stage_name(bits):
    named = {bit: name for bit, name, _group in TIC_STAGES}
    return "+".join(named.get(b, str(b)) for b in bits)


def profiled_variant():
    """doom_run_tic_core with a clock read either side of every stage.

    Generated from the real orchestrator rather than maintained separately, so
    it cannot drift: each stage is followed by "fired = fired | <bit>", which
    is the hook. Statements inside a CedarScript body are close to free -- 40
    trivial ones measure 0.05 ms in total -- so the instrumentation does not
    meaningfully disturb what it measures, and the stage times summing to the
    whole-tic time is the check that it did not.

    Only the core is instrumented. 40_run_game_tic.sql holds eleven functions
    now, so the body is cut at doom_run_tic_core's own dollar quotes rather
    than at the file's first and last -- the old span covered the whole file.
    The profiled wrapper repeats what doom_run_game_tic does around the core,
    minus the demo bookkeeping, which is not a stage and is not timed.
    """
    src = (PROJECT_ROOT / "sql/runtime/functions/40_run_game_tic.sql").read_text()
    head = src.index("CREATE OR REPLACE FUNCTION doom_run_tic_core(")
    start = src.index("$doom$", head) + 6
    body = src[start:src.index("$doom$", start)]
    # Cheap, but it is the check that matters: when this span ran past the
    # core's closing quote it took ten more CREATEs with it, and the trailing
    # text replaced the real doom_run_tic_core with an instrumented one that
    # no longer compiled -- which then broke every PREPARE in the database.
    assert "$doom$" not in body and "CREATE OR REPLACE" not in body, \
        "doom_run_tic_core's body was not extracted cleanly"
    out = ["let mut t0 = 0.0::float8;", "let mut t1 = 0.0::float8;",
           "SELECT EXTRACT(EPOCH FROM clock_timestamp()) AS e { t0 = e; }"]
    for line in body.splitlines():
        out.append(line)
        # The assignment is often inside a one-line "if ... { ... }", so this
        # searches rather than anchors -- the old anchored pattern silently
        # missed every gated stage, which is why begin/scrollers/walkover/
        # pickups/damage never appeared in a profile.
        m = re.search(r"fired = fired \|([^;]*);", line)
        if m:
            bits = [int(b) for b in re.findall(r"(\d+)::bigint", m.group(1))]
            indent = line[:len(line) - len(line.lstrip())]
            name = _stage_name(bits)
            out.append(f"{indent}SELECT EXTRACT(EPOCH FROM clock_timestamp())"
                       f" AS e {{ t1 = e; }}")
            out.append(f"{indent}INSERT INTO tic_profile (stage, seconds)"
                       f" VALUES (\'{name}\', t1 - t0);")
            out.append(f"{indent}t0 = t1;")
    return ("CREATE OR REPLACE FUNCTION doom_run_tic_core_profiled("
            "p_map_id integer, p_skill integer, p1 integer, p2 integer,"
            " p3 integer, p4 integer) RETURNS boolean\n"
            "LANGUAGE cedarscript AS $doom$\n" + "\n".join(out) + "\n$doom$;",
            "CREATE OR REPLACE FUNCTION doom_run_game_tic_profiled("
            "p_map_id integer, p_player_thing_id integer, p_skill integer,"
            "p_move_fwd real, p_move_strafe real, p_running boolean,"
            "p_turn_degrees real, p_attack_held boolean,"
            "p_weapon_switch_to integer, p_use_requested boolean)"
            " RETURNS boolean\nLANGUAGE cedarscript AS $doom$\n"
            "doom_cs_begin(p_map_id,p_player_thing_id,p_skill,p_move_fwd,"
            "p_move_strafe,p_running,p_turn_degrees,p_attack_held,"
            "p_weapon_switch_to,p_use_requested);\n"
            "let nobody = NULL::int;\n"
            "return doom_run_tic_core_profiled(p_map_id,p_skill,"
            "p_player_thing_id,nobody,nobody,nobody);\n$doom$;")


def profiled_blocks(variant_sql):
    """The timed blocks the instrumented tic emits, in pipeline order.

    Taken from the generated text rather than from TIC_STAGES, because one
    block can cover several stages and only the generator knows the grouping.
    """
    return re.findall(r"INSERT INTO tic_profile \(stage, seconds\)"
                      r" VALUES \('([^']+)'", variant_sql)


def drop_profiled(cur):
    """Leave no instrumented function behind.

    A half-written one is not inert: CedarDB compiles every function when a
    statement is prepared, so a broken doom_*_profiled makes an unrelated
    PREPARE fail in a later session with an error that points nowhere near it.
    """
    cur.execute("DROP FUNCTION IF EXISTS doom_run_game_tic_profiled"
                "(integer,integer,integer,real,real,boolean,real,boolean,"
                "integer,boolean)")
    cur.execute("DROP FUNCTION IF EXISTS doom_run_tic_core_profiled"
                "(integer,integer,integer,integer,integer,integer)")
    cur.execute("DROP TABLE IF EXISTS tic_profile")


def profile(cur, stage, skill, tics, inputs=WALK_FIRE):
    """Where one tic's time actually goes, measured inside the pipeline."""
    map_id, player_id = stage["map_id"], stage["player_thing_id"]
    cur.execute("CREATE TABLE IF NOT EXISTS tic_profile "
                "(stage TEXT, seconds FLOAT8)")
    for stmt in profiled_variant():
        cur.execute(stmt)
    cur.execute("""PREPARE tic_prof(int,int,int,real,real,boolean,real,
                   boolean,int,boolean) AS SELECT doom_run_game_tic_profiled(
                   $1,$2,$3,$4,$5,$6,$7,$8,$9,$10)""")
    args = (map_id, player_id, skill) + inputs
    call = "EXECUTE tic_prof(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)"
    for _ in range(8):
        cur.execute(call, args)
        cur.fetchall()
    cur.execute("TRUNCATE tic_profile")
    # What the tic itself says it ran, OR'd over the pass. The profiler's own
    # hooks cannot answer this: a single-line "if ... { fired = ... }" puts the
    # clock read after the brace, so those blocks are timed whether they fired
    # or not. tic_trace holds only the last tic, hence the running OR -- taking
    # one tic's mask called missiles skipped on a pass that plainly fired them.
    mask, elapsed = 0, 0.0
    for _ in range(tics):
        started = time.perf_counter()
        cur.execute(call, args)
        cur.fetchall()
        sql.finish_game_tic(cur, map_id, player_id)
        elapsed += time.perf_counter() - started
        # Outside the timer: reading the mask is the profiler's business, not
        # the tic's, and it would otherwise show up as a third round trip.
        cur.execute("SELECT stages FROM tic_trace WHERE map_id=%s"
                    " AND player_thing_id=%s", (map_id, player_id))
        row = cur.fetchone()
        mask |= 0 if row is None else int(row[0])
    whole = elapsed / tics * 1000.0
    cur.execute("""SELECT stage, count(*), avg(seconds)*1000, max(seconds)*1000
                   FROM tic_profile GROUP BY stage""")
    rows = cur.fetchall()
    cur.execute("DEALLOCATE tic_prof")
    # A stage that runs on only some tics costs its average times how often it
    # runs, which is what actually shows up in a frame's budget.
    scored = sorted(
        ((st, int(cnt), float(avg), float(mx), float(avg) * int(cnt) / tics)
         for st, cnt, avg, mx in rows), key=lambda r: -r[4])
    print(f"\nwhere one tic goes ({tics} tics, measured in-pipeline)")
    print(f"{'stage':<22} {'ran':>5} {'avg ms':>8} {'max ms':>8} "
          f"{'ms/tic':>8}  share")
    per_tic = sum(r[4] for r in scored) or 1.0
    for st, cnt, avg, mx, contrib in scored:
        print(f"{st:<22} {cnt:5d} {avg:8.3f} {mx:8.3f} {contrib:8.3f}  "
              f"{100*contrib/per_tic:5.1f}%")
    print(f"{'stages, per tic':<22} {'':>5} {'':>8} {'':>8} {per_tic:8.3f}")
    print(f"{'whole tic':<22} {'':>5} {'':>8} {'':>8} {whole:8.3f}"
          f"  (plus two client round trips)")
    # ms/tic, not the raw average: a stage that runs every other tic costs half
    # its average in a frame's budget, and that is what the figure stacks.
    # Both numbers matter and they differ by an order of magnitude: contrib is
    # what the stage costs a frame's budget on average, avg is what it costs on
    # a tic where it actually runs. Opening a door is 0.6 ms amortised and
    # 7.8 ms when it happens.
    return {st: (contrib, avg, cnt) for st, cnt, avg, _mx, contrib in scored}, mask


# Doors, switches and lifts: the specials whose activation puts a sector mover
# in motion, which is what keeps the use/specials/movers stages alive.
USABLE_SPECIALS = (1, 26, 27, 28, 31, 32, 33, 34, 63, 61, 29, 42, 50, 103,
                   10, 21, 62, 88, 121, 122, 123, 120, 87, 53, 54, 89)


def worst_case_spot(cur, map_id):
    """The usable line with the most live monsters around it.

    A worst-case tic has to fire the world stages and the combat stages at the
    same time, so the scene is a door with a crowd behind it. Searched rather
    than relocating anything: the point is weaker if the crowd was put there.
    """
    cur.execute("""
      SELECT l.linedef_id, count(*),
             count(*) FILTER (WHERE t.type IN (3001,3002,3005,68,69,71))
      FROM linedef_geom l
      JOIN things t ON t.map_id=l.map_id
      JOIN thing_health h ON h.map_id=t.map_id AND h.thing_id=t.id AND h.alive
      JOIN monster_ai a ON a.map_id=t.map_id AND a.thing_id=t.id
      WHERE l.map_id=%s AND l.special = ANY(%s)
        AND sqrt(power(t.x-(l.x1+l.x2)/2.0,2)
               + power(t.y-(l.y1+l.y2)/2.0,2)) < 400
      GROUP BY l.linedef_id ORDER BY 2 DESC LIMIT 1""",
      (map_id, list(USABLE_SPECIALS)))
    return cur.fetchone()


def capture_frame(cur, stage, skill, path):
    """The view from where the profiled tic is standing, as a PNG.

    Rendered after the pass rather than before it, so the picture is the scene
    the numbers were measured in -- doors part way open, monsters mid-charge.
    """
    from PIL import Image
    map_id, player_id = stage["map_id"], stage["player_thing_id"]
    cur.execute("""SELECT position_x, position_y, view_z, view_angle,
                          damage_count, bonus_count
                   FROM player_state WHERE map_id=%s AND player_thing_id=%s""",
                (map_id, player_id))
    row = cur.fetchone()
    pose, flash = [float(v) for v in row[:4]], (row[4], row[5])
    # A worst-case tic means taking a worst-case beating, and the damage
    # palette wash comes out a flat red that hides the room entirely. It is
    # zeroed for the render and put straight back: the geometry, the monsters
    # and the lighting are all still the tic's own, only the full-screen tint
    # is off. The caption says so.
    cur.execute("""UPDATE player_state SET damage_count=0, bonus_count=0
                   WHERE map_id=%s AND player_thing_id=%s""",
                (map_id, player_id))
    try:
        raw = sql.render_frame(cur, map_id, player_id, skill, pose)
    finally:
        cur.execute("""UPDATE player_state SET damage_count=%s, bonus_count=%s
                       WHERE map_id=%s AND player_thing_id=%s""",
                    (flash[0], flash[1], map_id, player_id))
    Image.frombytes("RGB", (320, 200), raw).save(path)
    print(f"wrote {path} (damage flash was {flash[0]}, suppressed for the shot)")


def write_figure_data(cur, stage, skill, tics, path):
    """Three profiled passes, in pipeline order, for the waterfall figures.

    busy  -- WALK_FIRE in the map's densest monster cluster, full arsenal.
    idle  -- a reset level and no input at all.
    worst -- everything at once: standing at a door with a crowd behind it,
             moving, turning, shooting and pressing use on every tic.
    Each scene is built here rather than inherited from run(), which leaves a
    reset level behind it and so made the busy pass skip nothing.
    """
    map_id, player_id = stage["map_id"], stage["player_thing_id"]
    blocks = profiled_blocks(profiled_variant()[0])
    s = Stress(cur, map_id, player_id, skill)
    passes, awake = {}, {}
    for phase, command in (("busy", WALK_FIRE), ("idle", IDLE),
                           ("worst", WORST)):
        print(f"\n--- {phase} tic ---")
        sql.reset_stage(cur, map_id, skill)
        spawn = sql.spawn_stage(cur, stage)
        if phase == "busy":
            cur.execute("""SELECT AVG(t.x), AVG(t.y), count(*) FROM things t
                           JOIN thing_health h
                             ON h.map_id=t.map_id AND h.thing_id=t.id
                           JOIN monster_ai a
                             ON a.map_id=t.map_id AND a.thing_id=t.id
                           WHERE t.map_id=%s AND h.alive
                           GROUP BY (t.x/512)::int, (t.y/512)::int
                           ORDER BY 3 DESC LIMIT 1""", (map_id,))
            row = cur.fetchone()
            if row and row[0] is not None:
                sql.cheat_give_arsenal(cur, map_id, player_id)
                s.place(float(row[0]), float(row[1]))
        elif phase == "worst":
            row = worst_case_spot(cur, map_id)
            if row is None:
                raise SystemExit(f"{stage['label']} has no usable line with"
                                 " monsters near it; pick another map")
            line_id, near, ranged = row
            print(f"line {line_id}: {near} live monsters within 400,"
                  f" {ranged} of them ranged")
            spot = s.line_front(line_id)
            if spot is None or not s.place(*spot):
                raise SystemExit(f"could not stand in front of line {line_id}")
            sql.cheat_give_arsenal(cur, map_id, player_id)
        else:
            s.place(spawn[0], spawn[1], spawn[2])
        timed, mask = profile(cur, stage, skill, tics, command)
        if phase == "worst":
            capture_frame(cur, stage, skill,
                          str(Path(path).with_suffix("")) + "_frame.png")
        cur.execute("SELECT count(*) FROM monster_ai WHERE map_id=%s"
                    " AND state <> 'stand'", (map_id,))
        awake[phase] = cur.fetchone()[0]
        # Skipped means the planner left every stage in the block out of the
        # mask -- the tic's own account of what it ran.
        bits = {name: bit for bit, name, _group in TIC_STAGES}
        # [name, ms/tic, skipped, ms when it runs, tics it ran on]
        passes[phase] = [
            [b, round(timed.get(b, (0.0, 0.0, 0))[0], 4),
             not any(mask & bits.get(part, 0) for part in b.split("+")),
             round(timed.get(b, (0.0, 0.0, 0))[1], 4),
             timed.get(b, (0.0, 0.0, 0))[2]]
            for b in blocks]
    data = {"map": stage["label"].split()[0], "tics": tics,
            "awake": awake["busy"], "awake_by_pass": awake,
            "busy": passes["busy"], "idle": passes["idle"],
            "worst": passes["worst"]}
    Path(path).write_text(json.dumps(data, indent=1) + "\n")
    print(f"\nwrote {path}")


def stage_names(mask):
    return ",".join(n for bit, n, _ in TIC_STAGES if mask & bit) or "-"


def run(cur, stage, skill, tics):
    map_id, player_id = stage["map_id"], stage["player_thing_id"]
    s = Stress(cur, map_id, player_id, skill)

    sql.reset_stage(cur, map_id, skill)
    spawn = sql.spawn_stage(cur, stage)

    # --- the plain paths ---
    s.phase("idle (clock only)", IDLE, tics=tics)
    s.place(spawn[0], spawn[1], spawn[2])
    s.phase("walk", WALK, tics=tics)
    s.place(spawn[0], spawn[1], spawn[2])
    s.phase("run", RUN, tics=tics)
    s.phase("turn", TURN, tics=tics)

    # --- world: a switch or door line, used ---
    cur.execute("""SELECT id FROM linedefs WHERE map_id=%s
                   AND special IN (1,26,27,28,31,32,33,34,63,61,29,42,50,103)
                   ORDER BY id LIMIT 1""", (map_id,))
    row = cur.fetchone()
    if row:
        spot = s.line_front(row[0])
        if spot and s.place(*spot):
            s.phase(f"use a door/switch (line {row[0]})", USE, tics=tics)

    # --- world: a lift/platform in motion ---
    cur.execute("""SELECT id, tag FROM linedefs WHERE map_id=%s
                   AND special IN (10,21,62,88,121,122,123,120,87,53,54,89)
                   ORDER BY id LIMIT 1""", (map_id,))
    row = cur.fetchone()
    if row:
        spot = s.line_front(row[0], back=16.0)
        if spot and s.place(*spot):
            s.phase(f"lift/mover running (line {row[0]})", USE, tics=tics)

    # --- player: a damaging floor, which also drives the palette flash ---
    cur.execute("""SELECT id FROM sectors WHERE map_id=%s
                   AND special IN (4,5,7,11,16) ORDER BY id LIMIT 1""",
                (map_id,))
    row = cur.fetchone()
    if row:
        spot = s.point_in_sector(row[0])
        if spot and s.place(*spot):
            s.phase(f"standing in a damaging sector ({row[0]})", IDLE, tics=tics)

    # --- player: pickups, standing in the densest cluster of items ---
    cur.execute("""SELECT t.x, t.y, count(*) FROM things t
                   JOIN pickup_defs d ON d.thing_type=t.type
                   WHERE t.map_id=%s GROUP BY t.x, t.y ORDER BY 3 DESC, 1
                   LIMIT 1""", (map_id,))
    row = cur.fetchone()
    if row and s.place(float(row[0]) - 24, float(row[1])):
        s.phase("walking over items", WALK, tics=tics)

    # --- combat: the densest monster cluster, shot at ---
    cur.execute("""SELECT AVG(t.x), AVG(t.y), count(*) FROM things t
                   JOIN thing_health h ON h.map_id=t.map_id AND h.thing_id=t.id
                   JOIN monster_ai a ON a.map_id=t.map_id AND a.thing_id=t.id
                   WHERE t.map_id=%s AND h.alive
                   GROUP BY (t.x/512)::int, (t.y/512)::int
                   ORDER BY 3 DESC LIMIT 1""", (map_id,))
    row = cur.fetchone()
    if row and row[0] is not None:
        cx, cy, n = float(row[0]), float(row[1]), row[2]
        sql.cheat_give_arsenal(cur, map_id, player_id)
        if s.place(cx, cy):
            s.phase(f"{n} monsters awake, holding fire", FIRE, tics=tics)
            s.phase(f"{n} monsters, moving and firing", WALK_FIRE, tics=tics)

    # --- combat: monster projectiles in flight ---
    cur.execute("SELECT count(*) FROM monster_projectiles WHERE map_id=%s",
                (map_id,))
    s.phase(f"after combat ({cur.fetchone()[0]} projectiles live)", IDLE,
            tics=tics)

    # --- death and respawn ---
    cur.execute("""UPDATE player_state SET health=0, alive=FALSE
                   WHERE map_id=%s AND player_thing_id=%s""",
                (map_id, player_id))
    s.phase("dead (view sinking)", IDLE, tics=tics)
    sql.reset_stage(cur, map_id, skill)
    sql.spawn_stage(cur, stage)

    # --- save/load, and the screen compositor ---
    started = time.perf_counter()
    sql.save_game(cur, 9, map_id, player_id, skill, "stress")
    s.note("save_game", time.perf_counter() - started)
    started = time.perf_counter()
    sql.load_game(cur, 9)
    s.note("load_game", time.perf_counter() - started)
    for screen in ("title", "main", "load", "intermission"):
        sql.set_screen(cur, screen)
        sql.render_screen(cur, 0)
        started = time.perf_counter()
        for _ in range(5):
            sql.render_screen(cur, 0)
        s.note(f"render_screen: {screen}", (time.perf_counter() - started) / 5)
    sql.set_screen(cur, "title")
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--map", default="E1M6")
    # Doom's 0..4 skill, as G_InitNew takes it.
    ap.add_argument("--skill", type=int, choices=(0, 1, 2, 3, 4), default=3)
    ap.add_argument("--tics", type=int, default=40)
    ap.add_argument("--profile", action="store_true",
                    help="also break one tic down by stage, in-pipeline")
    ap.add_argument("--figure-data", metavar="PATH",
                    help="write docs/figures/tic_stages.json from that"
                         " breakdown (busy and idle pass)")
    args = ap.parse_args()

    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    stages = sql.load_stages(cur)
    stage = next((st for st in stages if st["label"].startswith(args.map)), None)
    if stage is None:
        raise SystemExit(f"{args.map} is not loaded")
    if stage["map_id"] == 1:
        print("note: this resets the level it runs on", file=sys.stderr)
    # Folded: this harness renders hundreds of frames on one map, so the
    # per-level preparation is paid once and the 3.2 ms a frame is all gain.
    sql.prepare_renderer(cur, stage["map_id"], stage["player_thing_id"],
                         args.skill)

    print(f"stressing {stage['label']} at skill {args.skill}, "
          f"{args.tics} timed tics per phase\n")
    s = run(cur, stage, args.skill, args.tics)

    width = max(len(r["phase"]) for r in s.results)
    print(f"{'phase':<{width}}  tic p50  tic p95  tic max  render  stages")
    for r in s.results:
        p95 = f"{r['tic_p95']:7.2f}" if r["tic_p95"] is not None else "      -"
        mx = f"{r['tic_max']:7.2f}" if r["tic_max"] is not None else "      -"
        rd = f"{r['render_p50']:6.1f}" if r["render_p50"] is not None else "     -"
        print(f"{r['phase']:<{width}}  {r['tic_p50']:7.2f}  {p95}  {mx}  {rd}  "
              f"{stage_names(r['stages'])}")

    if args.figure_data or args.profile:
        try:
            if args.figure_data:
                write_figure_data(cur, stage, args.skill, args.tics,
                                  args.figure_data)
            else:
                profile(cur, stage, args.skill, args.tics)
        finally:
            drop_profiled(cur)

    missed = [n for bit, n, _ in TIC_STAGES if not (s.stages_seen & bit)]
    print(f"\nstages exercised: "
          f"{bin(s.stages_seen).count('1')}/{len(TIC_STAGES)}")
    for name in missed:
        # A stage can be unreachable because the harness failed to set it up,
        # or because the map simply has nothing that triggers it. Those are
        # very different results, so say which.
        needs = STAGE_NEEDS.get(name)
        if needs is None:
            print(f"  {name}: not reached")
            continue
        cur.execute(needs[1], (stage["map_id"],))
        have = cur.fetchone()[0]
        print(f"  {name}: not reached -- {stage['label']} has "
              f"{have} {needs[0]}"
              + (" (nothing to trigger it)" if have == 0 else ""))
    if not missed:
        print("every tic stage was reached at least once")


if __name__ == "__main__":
    main()
