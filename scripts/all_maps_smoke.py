#!/usr/bin/env python3
"""Every loaded map: reset, spawn, a scripted minute of play, and a frame.

Catches the class of bug a single map never shows -- a special, a thing type,
a texture only another episode uses -- by running the real tic and the real
renderer over every map in the database and reporting per map.

    python3 scripts/all_maps_smoke.py "<owner dsn>" [--tics 120]
"""
import argparse
import os
import sys
import time

import psycopg2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import doom_sql as sql  # noqa: E402
from determinism_check import script  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dsn")
    ap.add_argument("--tics", type=int, default=120)
    args = ap.parse_args()
    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    cur.execute("SELECT map_id, name FROM maps ORDER BY map_id")
    maps = cur.fetchall()
    failures = 0
    for map_id, name in maps:
        cur.execute("SELECT id FROM things WHERE map_id=%s AND type=1 LIMIT 1", (map_id,))
        row = cur.fetchone()
        if row is None:
            print(f"  {name}: no player start"); failures += 1; continue
        pid = int(row[0])
        try:
            sql.reset_stage(cur, map_id, 3)
            sql.spawn_stage(cur, {"map_id": map_id, "player_thing_id": pid})
            cur.execute("SELECT doom_cheat_arsenal(%s,%s)", (map_id, pid))
            t0 = time.perf_counter()
            for command in script(3, args.tics, 1):
                sql.execute_game_tic(cur, map_id, pid, command)
            tic_ms = (time.perf_counter() - t0) * 1000 / args.tics
            cur.execute("SELECT position_x, position_y, view_z, view_angle, health FROM player_state "
                        "WHERE map_id=%s AND player_thing_id=%s", (map_id, pid))
            x, y, z, a, hp = cur.fetchone()
            sql.prepare_renderer(cur, map_id, pid, 3)
            t0 = time.perf_counter()
            frame = sql.render_frame(cur, map_id, pid, 3, (float(x), float(y), float(z), float(a)))
            frame_ms = (time.perf_counter() - t0) * 1000
            frame = bytes(frame)
            distinct = len(set(frame[i] for i in range(0, len(frame), 97)))
            ok = len(frame) == 192000 and distinct > 8
            failures += 0 if ok else 1
            print(f"  {name}: {'ok ' if ok else 'BAD'} {args.tics} tics at {tic_ms:.1f} ms, frame {frame_ms:.0f} ms "
                  f"({distinct} distinct sampled bytes), hp {hp}")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            conn.rollback()
            print(f"  {name}: ERROR {exc.__class__.__name__}: {str(exc).splitlines()[0][:140]}")
    print(f"{len(maps) - failures}/{len(maps)} maps ok")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
