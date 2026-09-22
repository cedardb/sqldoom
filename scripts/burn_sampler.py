#!/usr/bin/env python3
"""Every minute, one CSV row about the running match: mp_stats, the referee's
latest tic figures from its log, row counts of every gameplay table, the
CedarDB and relay processes' memory, the relay's guest seats.

    python3 scripts/burn_sampler.py "<owner dsn>" <referee log> <relay config url> <csv> [seconds]
"""
import csv
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

import psycopg2

TABLES = ["things", "thing_health", "monster_ai", "monster_deaths", "monster_steps", "monster_projectiles",
          "projectile_impacts", "projectile_damage", "hitscan_hits", "world_effects", "sound_events",
          "picked_up_items", "item_respawns", "pickup_touches", "pickup_grants", "line_special_events",
          "line_use_results", "line_activations", "line_buttons", "sector_movers", "sector_light_fx",
          "mp_inputs", "mp_players", "mp_join_requests", "game_tic_commands", "tic_trace", "player_state",
          "mapped_lines", "level_stats"]
TIC_RE = re.compile(r"tic ([\d.]+) ms p90 ([\d.]+) max ([\d.]+), (\d+) tics, (\d+) dropped")


def rss_mb(pattern):
    try:
        pids = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split()
        total = 0.0
        for pid in pids:
            with open(f"/proc/{pid}/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        total += int(line.split()[1]) / 1024
        return round(total, 1), len(pids)
    except OSError:
        return None, 0


def connect(dsn):
    """A sampling connection"""
    conn = psycopg2.connect(dsn); conn.autocommit = True; cur = conn.cursor()
    try:
        cur.execute("SET max_parallel_workers = 8")
    except psycopg2.Error:
        conn.rollback()
    return conn, cur


def main():
    dsn, log_path, config_url, out, period = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5] if len(sys.argv) > 5 else 60)
    conn, cur = connect(dsn)
    new = not os.path.exists(out)
    f = open(out, "a", newline=""); w = csv.writer(f)
    head = ["time", "map", "state", "level_s", "maps_played", "tic_med", "tic_p90", "tic_max", "tics", "dropped",
            "monsters_alive", "monsters_total", "monsters_awake", "projectiles", "effects", "items_out", "items_queued",
            "movers", "input_backlog", "sound_rows", "db_sessions", "slots_held", "guests_free",
            "db_rss_mb", "db_threads", "web_rss_mb", "referee_rss_mb"] + [f"rows_{t}" for t in TABLES]
    if new:
        w.writerow(head); f.flush()
    while True:
        row = [time.strftime("%Y-%m-%d %H:%M:%S")]
        try:
            cur.execute("SELECT map_name, state, level_tics, maps_played, monsters_alive, monsters_total, monsters_awake, "
                        "projectiles, effects, items_out, items_queued, movers, input_backlog, sound_rows, sessions FROM mp_stats")
            st = cur.fetchone() or [None] * 15
            cur.execute("SELECT count(*) FROM mp_players WHERE role_name IS NOT NULL"); held = cur.fetchone()[0]
            tic = [None] * 5
            try:
                with open(log_path, "rb") as lf:
                    lf.seek(max(0, os.path.getsize(log_path) - 20000))
                    for line in lf.read().decode("utf-8", "replace").splitlines():
                        m = TIC_RE.search(line)
                        if m:
                            tic = [float(m.group(1)), float(m.group(2)), float(m.group(3)), int(m.group(4)), int(m.group(5))]
            except OSError:
                pass
            guests_free = None
            try:
                guests_free = json.load(urllib.request.urlopen(config_url, timeout=5)).get("guests_free")
            except Exception:  # noqa: BLE001
                pass
            db_rss, _ = rss_mb("cedardb.*-port")
            threads = None
            try:
                pid = subprocess.run(["pgrep", "-f", "cedardb.*-port"], capture_output=True, text=True).stdout.split()[0]
                threads = len(os.listdir(f"/proc/{pid}/task"))
            except (IndexError, OSError):
                pass
            web_rss, _ = rss_mb("doom_web.py")
            ref_rss, _ = rss_mb("doom_server.py")
            row += [st[0], st[1], round(st[2] / 35, 1) if st[2] is not None else None, st[3]] + tic + list(st[4:15]) \
                + [held, guests_free, db_rss, threads, web_rss, ref_rss]
            for t in TABLES:
                cur.execute(f"SELECT count(*) FROM {t}"); row.append(cur.fetchone()[0])
        except Exception as exc:  # noqa: BLE001
            row += [f"error: {str(exc).splitlines()[0][:80]}"]
            try:
                conn.rollback()
            except Exception:  # noqa: BLE001
                conn, cur = connect(dsn)
        w.writerow(row); f.flush()
        time.sleep(period)


if __name__ == "__main__":
    main()
