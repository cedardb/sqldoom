#!/usr/bin/env python3
"""Fire every line special the catalogue knows on a real map and watch the
tagged sectors move: doors close, floors lower, crushers oscillate, lights
change. Bypasses the player's walk-over/press geometry by queueing the line
event directly, so this tests the dispatcher and the mover step, not the
crossing code.

    python3 scripts/specials_check.py "<owner dsn>" [--tics 260] [--specials 6,25,...]
"""
import argparse
import os
import sys

import psycopg2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import doom_sql as sql  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dsn")
    ap.add_argument("--tics", type=int, default=260)
    ap.add_argument("--specials", default="")
    args = ap.parse_args()
    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    cur.execute("SELECT special, mechanic, mover_type, height_target, target_light, light_source, stops_mover, "
                "use_activated, cross_activated, shoot_activated, key_required FROM line_special_defs "
                "WHERE mechanic IS NOT NULL ORDER BY special")
    defs = cur.fetchall()
    wanted = {int(v) for v in args.specials.split(",") if v}
    bad = 0
    for special, mech, mover, htarget, tlight, lsource, stops, use, cross, shoot, key in defs:
        if wanted and special not in wanted:
            continue
        # a line with this special whose tag has sectors (or a manual door with a back sector)
        cur.execute("""SELECT ld.map_id, ld.id, ld.tag FROM linedefs ld
                       WHERE ld.special=%s AND (
                         (ld.tag<>0 AND EXISTS (SELECT 1 FROM sectors s WHERE s.map_id=ld.map_id AND s.tag=ld.tag))
                         OR ld.left_sd_id IS NOT NULL)
                       ORDER BY ld.map_id, ld.id LIMIT 1""", (special,))
        row = cur.fetchone()
        if row is None:
            print(f"  {special:>3} {mech:<9} n/a (no line in any loaded map)")
            continue
        map_id, line_id, tag = row
        try:
            cur.execute("SELECT id FROM things WHERE map_id=%s AND type=1 LIMIT 1", (map_id,))
            pid = cur.fetchone()[0]
            sql.reset_stage(cur, map_id, 3)
            sql.spawn_stage(cur, {"map_id": map_id, "player_thing_id": pid})
            if key:
                cur.execute(f"UPDATE player_state SET key_{key}=TRUE WHERE map_id=%s", (map_id,))
            if tag:
                sect = "SELECT id, floor_height, ceil_height, light_level FROM sectors WHERE map_id=%s AND tag=%s ORDER BY id"
                sargs = (map_id, tag)
            else:
                sect = ("SELECT s.id, s.floor_height, s.ceil_height, s.light_level FROM linedefs ld "
                        "JOIN sidedefs sd ON sd.map_id=ld.map_id AND sd.id=ld.left_sd_id "
                        "JOIN sectors s ON s.map_id=sd.map_id AND s.id=sd.sector_id WHERE ld.map_id=%s AND ld.id=%s")
                sargs = (map_id, line_id)
            cur.execute(sect, sargs)
            before = {r[0]: r[1:] for r in cur.fetchall()}
            trigger = "use" if use else "cross" if cross else "shoot"
            cur.execute("INSERT INTO line_special_events (map_id,player_thing_id,line_id,trigger_type,from_front) "
                        "VALUES (%s,%s,%s,%s,TRUE) ON CONFLICT DO NOTHING", (map_id, pid, line_id, trigger))
            cur.execute("SELECT doom_cs_activate_specials(%s)", (map_id,))
            lo = dict(before); hi = dict(before)
            for _ in range(args.tics):
                cur.execute("UPDATE player_state SET level_tics=level_tics+1 WHERE map_id=%s", (map_id,))
                cur.execute("SELECT doom_cs_doors(%s,%s)", (map_id, pid))
                cur.execute(sect, sargs)
                for sid, fl, ce, li in cur.fetchall():
                    lo[sid] = (min(lo[sid][0], fl), min(lo[sid][1], ce), min(lo[sid][2], li))
                    hi[sid] = (max(hi[sid][0], fl), max(hi[sid][1], ce), max(hi[sid][2], li))
            cur.execute(sect, sargs)
            after = {r[0]: r[1:] for r in cur.fetchall()}
            cur.execute("SELECT mover_type, direction FROM sector_movers WHERE map_id=%s", (map_id,))
            movers = cur.fetchall()
            sid = next(iter(before))
            b, a, l, h = before[sid], after[sid], lo[sid], hi[sid]
            ok, note = True, ""
            if mech == "door":
                if mover in ("door_close", "door_close_open"):
                    # closes onto the floor (close_open reopens after 30 s, past this window)
                    ok = l[1] == b[0]
                else:
                    ok = h[1] > b[1]
                note = f"ceiling {b[1]}->{a[1]} (peak {h[1]}, low {l[1]}, floor {b[0]})"
            elif mech in ("floor", "raise"):
                # vanilla's destination from the neighbours, so a no-op is only
                # accepted when Doom would not have moved the floor either
                cur.execute("""SELECT o.floor_height, o.ceil_height FROM linedefs l
                               JOIN sidedefs r ON r.map_id=l.map_id AND r.id=l.right_sd_id
                               JOIN sidedefs lf ON lf.map_id=l.map_id AND lf.id=l.left_sd_id
                               JOIN sectors o ON o.map_id=l.map_id
                                AND o.id=CASE WHEN r.sector_id=%s THEN lf.sector_id ELSE r.sector_id END
                               WHERE l.map_id=%s AND l.left_sd_id<>-1 AND l.right_sd_id<>-1
                                 AND (r.sector_id=%s OR lf.sector_id=%s) AND o.id<>%s""",
                            (sid, map_id, sid, sid, sid))
                neigh = cur.fetchall()
                floors = [n[0] for n in neigh]; ceils = [n[1] for n in neigh]
                expected = None
                if htarget == "lowest":
                    expected = min(floors + [b[0]])
                elif htarget == "highest":
                    expected = max(floors) if floors else -500
                elif htarget == "highest8":
                    expected = (max(floors) + 8) if floors and max(floors) != b[0] else b[0]
                elif htarget == "next_floor":
                    higher = [f for f in floors if f > b[0]]
                    expected = min(higher) if higher else b[0]
                elif htarget in ("lowest_ceiling", "lowest_ceiling_minus8"):
                    expected = min(ceils + [b[1]]) - (8 if htarget.endswith("minus8") else 0)
                elif htarget in ("plus24", "plus32", "plus512"):
                    expected = b[0] + int(htarget[4:])
                if expected is None:
                    ok = a[0] != b[0]
                elif expected == b[0]:
                    ok = a[0] == b[0]
                else:
                    ok = a[0] == expected or (expected > b[0] and b[0] < a[0] <= expected) \
                         or (expected < b[0] and expected <= a[0] < b[0])
                note = f"floor {b[0]}->{a[0]} (vanilla destination {expected})"
            elif mech == "platform":
                ok = l[0] < b[0] or h[0] > b[0]; note = f"floor {b[0]} ranged {l[0]}..{h[0]}, now {a[0]}"
            elif mech == "ceiling":
                ok = (a[1] > b[1]) if mover == "ceiling_raise" else (a[1] < b[1]); note = f"ceiling {b[1]}->{a[1]}"
            elif mech == "crusher":
                ok = l[1] < b[1] and any(m[0] == "crusher" and m[1] != 2 for m in movers)
                note = f"ceiling {b[1]} ranged {l[1]}..{h[1]}, still running {any(m[0]=='crusher' and m[1]!=2 for m in movers)}"
            elif mech == "stop":
                # start the mover it stops, then stop it
                cur.execute("SELECT ld.id FROM linedefs ld JOIN line_special_defs d ON d.special=ld.special "
                            "WHERE ld.map_id=%s AND ld.tag=%s AND d.mover_type=%s LIMIT 1", (map_id, tag, stops))
                starter = cur.fetchone()
                if starter is None:
                    ok, note = True, "n/a (no matching mover shares the tag)"
                else:
                    cur.execute("INSERT INTO line_special_events VALUES (%s,%s,%s,'cross',TRUE) ON CONFLICT DO NOTHING", (map_id, pid, starter[0]))
                    cur.execute("SELECT doom_cs_activate_specials(%s)", (map_id,))
                    for _ in range(20):
                        cur.execute("SELECT doom_cs_doors(%s,%s)", (map_id, pid))
                    cur.execute("INSERT INTO line_special_events VALUES (%s,%s,%s,%s,TRUE) ON CONFLICT DO NOTHING", (map_id, pid, line_id, trigger))
                    cur.execute("SELECT doom_cs_activate_specials(%s)", (map_id,))
                    cur.execute("SELECT mover_type, direction FROM sector_movers WHERE map_id=%s AND mover_type=%s", (map_id, stops))
                    st = cur.fetchall()
                    ok = bool(st) and all(d == 2 for _, d in st); note = f"{stops} movers after stop: {st}"
            elif mech == "lights":
                if lsource == "strobe":
                    cur.execute("SELECT count(*) FROM sector_light_fx WHERE map_id=%s AND sector_id=%s", (map_id, sid))
                    ok = cur.fetchone()[0] == 1; note = "strobe row present" if ok else "no strobe row"
                else:
                    ok = a[2] != b[2] or (tlight is not None and a[2] == tlight); note = f"light {b[2]}->{a[2]} ({lsource or tlight})"
            elif mech == "stairs":
                ok = a[0] > b[0]; note = f"first step floor {b[0]}->{a[0]}"
            elif mech in ("teleport", "donut"):
                ok, note = True, "(not exercised here)"
            bad += 0 if ok else 1
            print(f"  {special:>3} {mech:<9} {'ok ' if ok else 'BAD'} map {map_id} line {line_id} tag {tag}: {note}")
        except Exception as exc:  # noqa: BLE001
            bad += 1
            conn.rollback()
            print(f"  {special:>3} {mech:<9} ERROR {exc.__class__.__name__}: {str(exc).splitlines()[0][:120]}")
    print("SPECIALS OK" if not bad else f"SPECIALS: {bad} problems")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
