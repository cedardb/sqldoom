#!/usr/bin/env python3
"""How many players can one database carry, and at what per-session parallelism?

Runs N renderer processes (each its own connection, each SET max_parallel_workers
= W, each drawing the folded renderer from a cycle of real poses as fast as it
can) next to one 35 Hz ticker process running doom_run_mp_tic, and reports per
cell: frames per second per renderer, total, and the ticker's frame time and
achieved rate. Run as the database owner, on the database host, with the
referee stopped (it would be a second ticker).

    python3 scripts/render_capacity.py "<owner dsn>" [--seconds 5] [--workers 1,2,4,8]
        [--parallel 4,8,16,32,64] [--tic-parallel 8] [--map 1]
"""
import argparse
import multiprocessing as mp
import os
import statistics
import sys
import time

import psycopg2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import doom_sql as sql  # noqa: E402


def set_parallel(cur, value):
    """Best effort: Current public verison doesn't have that setting yet and it works without, just slower"""
    if not value:
        return False
    return sql.set_session_parallel(cur, value)


def renderer(dsn, map_id, thing, skill, poses, parallel, seconds, barrier, out, index):
    # A worker that dies must still report, or the parent waits for ever.
    try:
        _renderer(dsn, map_id, thing, skill, poses, parallel, seconds, barrier, out, index)
    except Exception as exc:  # noqa: BLE001
        barrier.abort()
        out.put(("render", index, 0.0, 0.0, 0.0, f"{exc.__class__.__name__}: {str(exc).splitlines()[0][:80]}"))


def _renderer(dsn, map_id, thing, skill, poses, parallel, seconds, barrier, out, index):
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    cur = conn.cursor()
    set_parallel(cur, parallel)
    sql.prepare_renderer(cur, map_id, thing, skill)
    for pose in poses[:3]:
        sql.render_frame(cur, map_id, thing, skill, pose)
        cur.fetchone()
    barrier.wait()
    frames, times = 0, []
    t_end = time.perf_counter() + seconds
    while time.perf_counter() < t_end:
        t0 = time.perf_counter()
        sql.render_frame(cur, map_id, thing, skill, poses[frames % len(poses)])
        cur.fetchone()
        times.append(time.perf_counter() - t0)
        frames += 1
    elapsed = seconds
    times.sort()
    out.put(("render", index, frames / elapsed, times[len(times) // 2] * 1000, times[int(len(times) * 0.9)] * 1000))


def ticker(dsn, map_id, skill, players, parallel, seconds, barrier, out):
    try:
        _ticker(dsn, map_id, skill, players, parallel, seconds, barrier, out)
    except Exception as exc:  # noqa: BLE001
        barrier.abort()
        out.put(("tic", 0, 0.0, 0.0, 0.0, f"{exc.__class__.__name__}: {str(exc).splitlines()[0][:80]}"))


def _ticker(dsn, map_id, skill, players, parallel, seconds, barrier, out):
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    cur = conn.cursor()
    set_parallel(cur, parallel)
    sql.prepare_client(cur)
    for _ in range(3):
        sql.mp_tic(cur, map_id, skill, players)
    barrier.wait()
    times, tics = [], 0
    t_end = time.perf_counter() + seconds
    nxt = time.perf_counter()
    while time.perf_counter() < t_end:
        t0 = time.perf_counter()
        sql.mp_tic(cur, map_id, skill, players)
        times.append(time.perf_counter() - t0)
        tics += 1
        nxt += 1 / 35
        delay = nxt - time.perf_counter()
        if delay > 0:
            time.sleep(delay)
        elif delay < -0.5:
            nxt = time.perf_counter()
    times.sort()
    out.put(("tic", 0, tics / seconds, times[len(times) // 2] * 1000, times[int(len(times) * 0.9)] * 1000))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dsn")
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--workers", default="1,2,4,8")
    ap.add_argument("--parallel", default="4,8,16,32,64")
    ap.add_argument("--tic-parallel", type=int, default=8)
    ap.add_argument("--no-tic", action="store_true", help="renderers only, no 35 Hz ticker (isolates read-side contention)")
    ap.add_argument("--map", type=int, default=1)
    ap.add_argument("--skill", type=int, default=3)
    args = ap.parse_args()

    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    players = sql.mp_start(cur, args.map, args.skill)
    p1, p2 = players[1], players[2]
    # Real poses: respawn both players a few times and read where they stand.
    poses = []
    for _ in range(4):
        for thing in (p1, p2):
            cur.execute("SELECT doom_mp_respawn(%s,%s)", (args.map, thing))
            cur.execute("SELECT position_x, position_y, view_z, view_angle FROM player_state "
                        "WHERE map_id=%s AND player_thing_id=%s", (args.map, thing))
            poses.append(tuple(float(v) for v in cur.fetchone()))
    cur.execute("SELECT version()")
    version = cur.fetchone()[0][:60]
    wanted = sorted({int(v) for v in args.parallel.split(",")} | {int(args.tic_parallel)})
    refused = [v for v in wanted if not sql.set_session_parallel(cur, v)]
    try:
        cur.execute("SHOW max_parallel_workers")
        effective = cur.fetchone()[0]
    except psycopg2.Error:
        conn.rollback()
        effective = "unknown"
    print(f"{version}; {len(poses)} poses on map {args.map}; {args.seconds:.0f} s per cell; "
          + (f"ticker at max_parallel_workers={args.tic_parallel}" if not refused
             else f"this build would not take max_parallel_workers="
                  f"{','.join(str(v) for v in refused)} (it stays at {effective}): those rows "
                  f"say what the cell asked for, not what it ran at"))
    print(f"{'parallel':>8} {'renderers':>9} | {'fps/renderer (min..max)':>24} {'total fps':>9} | "
          f"{'tic med':>7} {'tic p90':>7} {'tic/s':>5}")
    ctx = mp.get_context("fork")
    for parallel in [int(v) for v in args.parallel.split(",")]:
        for workers in [int(v) for v in args.workers.split(",")]:
            out = ctx.Queue()
            barrier = ctx.Barrier(workers + (0 if args.no_tic else 1))
            procs = [ctx.Process(target=renderer, args=(args.dsn, args.map, p1, args.skill, poses, parallel,
                                                        args.seconds, barrier, out, i)) for i in range(workers)]
            if not args.no_tic:
                procs.append(ctx.Process(target=ticker, args=(args.dsn, args.map, args.skill, players,
                                                              args.tic_parallel, args.seconds, barrier, out)))
            for p in procs:
                p.start()
            results = [out.get(timeout=args.seconds + 60) for _ in procs]
            for p in procs:
                p.join()
            for r in results:
                if len(r) > 5:
                    print(f"    {r[0]} {r[1]} failed: {r[5]}")
            fps = sorted(r[2] for r in results if r[0] == "render")
            tic = next((r for r in results if r[0] == "tic"), ("tic", 0, 0.0, 0.0, 0.0))
            print(f"{parallel:>8} {workers:>9} | {fps[0]:>10.1f} .. {fps[-1]:<10.1f} {sum(fps):>9.1f} | "
                  f"{tic[3]:>6.1f} {tic[4]:>7.1f} {tic[2]:>5.1f}", flush=True)
    cur.execute("SELECT doom_mp_vacate_all(%s)", (args.map,))
    return 0


if __name__ == "__main__":
    sys.exit(main())
