#!/usr/bin/env python3
"""Put the player in front of one monster of each type and watch it fight:
does it wake, chase (floaters over steps), fire the right projectile or
hitscan, bite, charge, and does the frame with it in view render.

    python3 scripts/monsters_check.py "<owner dsn>" [--types 3005,3006,16,7] [--tics 420]
"""
import argparse
import math
import os
import sys

import psycopg2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import doom_sql as sql  # noqa: E402

STILL = (3, 0.0, 0.0, False, 0.0, False, None, False)
NAMES = {3005: "cacodemon", 3006: "lost soul", 16: "cyberdemon", 7: "spider mastermind",
         3001: "imp", 3004: "zombieman", 9: "shotgun guy", 3002: "demon", 3003: "baron"}
EXPECT = {3005: {"projectile": "caco_fireball", "floats": True},
          3006: {"charge": True, "floats": True},
          16: {"projectile": "rocket"},
          7: {"hitscan": True},
          3001: {"projectile": "imp_fireball"}, 9: {"hitscan": True}}


def clear_spot(cur, map_id, mx, my, dist):
    """A point `dist` from the monster that no linedef separates from it (so
    the same sector, the same height, and a clear line of sight)."""
    for k in range(16):
        a = 2 * math.pi * k / 16
        px, py = mx + dist * math.cos(a), my + dist * math.sin(a)
        cur.execute("""SELECT count(*) FROM linedef_geom ld
                       WHERE ld.map_id=%(m)s
                         AND ((%(px)s-ld.x1)*(ld.y2-ld.y1)-(%(py)s-ld.y1)*(ld.x2-ld.x1))
                            *((%(mx)s-ld.x1)*(ld.y2-ld.y1)-(%(my)s-ld.y1)*(ld.x2-ld.x1)) <= 0
                         AND ((ld.x1-%(px)s)*(%(my)s-%(py)s)-(ld.y1-%(py)s)*(%(mx)s-%(px)s))
                            *((ld.x2-%(px)s)*(%(my)s-%(py)s)-(ld.y2-%(py)s)*(%(mx)s-%(px)s)) <= 0""",
                    {"m": map_id, "px": px, "py": py, "mx": mx, "my": my})
        if cur.fetchone()[0] == 0:
            return px, py
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dsn")
    ap.add_argument("--types", default="3005,3006,16,7")
    ap.add_argument("--tics", type=int, default=420)
    args = ap.parse_args()
    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    bad = 0
    for ttype in (int(v) for v in args.types.split(",")):
        exp = EXPECT.get(ttype, {})
        # every monster of the type, nearest map first, until one has a clear spot
        cur.execute("""SELECT t.map_id, t.id, t.spawn_x, t.spawn_y, rt.sector_id, d.radius FROM things t
                       JOIN render_things rt ON rt.map_id=t.map_id AND rt.thing_id=t.id
                       JOIN thing_combat_defs d ON d.thing_type=t.type
                       WHERE t.type=%s ORDER BY t.map_id, t.id""", (ttype,))
        cands = cur.fetchall()
        placed = None
        for map_id, mid, mx, my, msec, radius in cands:
            for dist in (max(192, radius + 96), 256, 320, 128):
                spot = clear_spot(cur, map_id, float(mx), float(my), dist)
                if spot:
                    placed = (map_id, mid, float(mx), float(my), msec, spot)
                    break
            if placed:
                break
        if not placed:
            print(f"  {ttype:>4} {NAMES.get(ttype, '?'):<18} n/a (no clear spot on any loaded map)")
            continue
        map_id, mid, mx, my, msec, (px, py) = placed
        cur.execute("SELECT id FROM things WHERE map_id=%s AND type=1 LIMIT 1", (map_id,))
        pid = cur.fetchone()[0]
        try:
            sql.reset_stage(cur, map_id, 3)
            sql.spawn_stage(cur, {"map_id": map_id, "player_thing_id": pid})
            angle = math.degrees(math.atan2(my - py, mx - px)) % 360
            cur.execute("SELECT floor_height FROM sectors WHERE map_id=%s AND id=%s", (map_id, msec))
            floor = cur.fetchone()[0]
            cur.execute("UPDATE things SET x=%s, y=%s, z=%s, angle=%s WHERE map_id=%s AND id=%s",
                        (px, py, floor + 41, angle, map_id, pid))
            cur.execute("""UPDATE player_state SET position_x=%s, position_y=%s, previous_x=%s, previous_y=%s,
                           base_z=%s, view_z=%s, previous_view_z=%s, view_angle=%s, previous_view_angle=%s,
                           sector_id=%s, health=1000 WHERE map_id=%s AND player_thing_id=%s""",
                        (px, py, px, py, floor + 41, floor + 41, floor + 41, angle, angle, msec, map_id, pid))
            # P_LookForPlayers needs the player inside the monster's half-plane
            # of view unless there was noise: turn it round to face the player
            cur.execute("UPDATE things SET angle=%s WHERE map_id=%s AND id=%s",
                        ((angle + 180) % 360, map_id, mid))
            # make sure this one is the monster that gets to fight: put the rest to sleep for good
            cur.execute("UPDATE thing_health h SET alive=FALSE, health=0 FROM monster_ai ai "
                        "WHERE ai.map_id=h.map_id AND ai.thing_id=h.thing_id AND h.map_id=%s AND h.thing_id<>%s",
                        (map_id, mid))
            states, ptypes, zs, poss = set(), {}, [], []
            hits = charge = 0
            hp0 = 1000
            for _ in range(args.tics):
                sql.execute_game_tic(cur, map_id, pid, STILL)
                cur.execute("SELECT ai.state, ai.charge_tics, t.x, t.y, t.z FROM monster_ai ai "
                            "JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id WHERE ai.map_id=%s AND ai.thing_id=%s",
                            (map_id, mid))
                st, ct, x, y, z = cur.fetchone()
                states.add(st); charge = max(charge, ct); zs.append(float(z)); poss.append((float(x), float(y)))
                cur.execute("SELECT projectile_type, count(*) FROM monster_projectiles WHERE map_id=%s AND owner_thing_id=%s GROUP BY 1",
                            (map_id, mid))
                for pt, n in cur.fetchall():
                    ptypes[pt] = max(ptypes.get(pt, 0), n)
            cur.execute("SELECT health FROM player_state WHERE map_id=%s AND player_thing_id=%s", (map_id, pid))
            hp = cur.fetchone()[0]
            moved = max(math.hypot(x - mx, y - my) for x, y in poss)
            # a frame with the monster in view
            sql.prepare_renderer(cur, map_id, pid, 3)
            frame = bytes(sql.render_frame(cur, map_id, pid, 3, (px, py, floor + 41, angle)))
            ok = len(frame) == 192000 and "see" in states
            notes = [f"map {map_id} thing {mid} at {math.hypot(px-mx, py-my):.0f} units", f"states {sorted(states)}",
                     f"moved {moved:.0f}", f"damage taken {hp0-hp}"]
            if exp.get("projectile"):
                n = ptypes.get(exp["projectile"], 0)
                ok = ok and n > 0
                notes.append(f"{exp['projectile']} x{n} (all: {ptypes})")
            if exp.get("hitscan"):
                ok = ok and hp0 - hp > 0
            if exp.get("charge"):
                notes.append(f"longest charge {charge} tics")
                ok = ok and charge > 0
            if exp.get("floats"):
                notes.append(f"z {min(zs):.0f}..{max(zs):.0f} (floor {floor})")
            if not exp.get("charge"):
                ok = ok and (hp0 - hp) > 0
            bad += 0 if ok else 1
            print(f"  {ttype:>4} {NAMES.get(ttype, '?'):<18} {'ok ' if ok else 'BAD'} " + "; ".join(notes))
        except Exception as exc:  # noqa: BLE001
            bad += 1
            conn.rollback()
            print(f"  {ttype:>4} {NAMES.get(ttype, '?'):<18} ERROR {exc.__class__.__name__}: {str(exc).splitlines()[0][:160]}")
    print("MONSTERS OK" if not bad else f"MONSTERS: {bad} problems")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
