#!/usr/bin/env python3
"""Summarise a burn_sampler.py CSV: first hour against the last hour, the
worst values, and anything that grew steadily.

    python3 scripts/burn_report.py <csv>
"""
import csv
import statistics
import sys


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def main():
    rows = list(csv.DictReader(open(sys.argv[1])))
    rows = [r for r in rows if r.get("tic_med") not in (None, "", "None") and not str(r.get("map", "")).startswith("error")]
    if len(rows) < 3:
        print("not enough samples"); return 1
    hours = (len(rows) - 1) / 60
    first, last = rows[:60], rows[-60:]
    print(f"{len(rows)} samples over {hours:.1f} h, {rows[0]['time']} to {rows[-1]['time']}")
    maps = [r["map"] for r in rows]
    switches = sum(1 for a, b in zip(maps, maps[1:]) if a != b)
    print(f"maps played (sampled) {rows[-1]['maps_played']}, map switches seen {switches}, dropped tics total {sum(int(num(r['dropped']) or 0) for r in rows)}")
    print(f"{'metric':<22}{'first hour':>16}{'last hour':>16}{'max':>12}")
    for key in ["tic_med", "tic_p90", "tic_max", "monsters_alive", "monsters_awake", "projectiles", "effects", "items_out",
                "items_queued", "input_backlog", "sound_rows", "db_sessions", "slots_held", "guests_free", "db_rss_mb",
                "db_threads", "web_rss_mb", "referee_rss_mb"]:
        a = [num(r[key]) for r in first if num(r[key]) is not None]
        b = [num(r[key]) for r in last if num(r[key]) is not None]
        c = [num(r[key]) for r in rows if num(r[key]) is not None]
        if not a or not b:
            continue
        print(f"{key:<22}{statistics.median(a):>16.1f}{statistics.median(b):>16.1f}{max(c):>12.1f}")
    print("\ntable rows (median of the first hour, of the last hour, max); a table that keeps growing is the thing to look at:")
    for key in rows[0]:
        if not key.startswith("rows_"):
            continue
        a = [num(r[key]) for r in first if num(r[key]) is not None]
        b = [num(r[key]) for r in last if num(r[key]) is not None]
        c = [num(r[key]) for r in rows if num(r[key]) is not None]
        if not a or not b:
            continue
        flag = "  <-- grows" if statistics.median(b) > 2 * max(50, statistics.median(a)) else ""
        print(f"  {key[5:]:<22}{statistics.median(a):>12.0f}{statistics.median(b):>12.0f}{max(c):>12.0f}{flag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
