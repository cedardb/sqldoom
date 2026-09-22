#!/usr/bin/env python3
"""The steady-state match: a referee with a short -timer and a two-map
rotation, two bot players through the API, and an admin watching. Checks that
the level ends on the timer, the intermission runs, the match moves to the
next map with the same players in the same slots and zero frags, the bots
keep getting frames there, monsters are in, and a taken item comes back
after 30 seconds with its fog and sound.

    python3 scripts/mp_rotation_check.py OWNER_DSN P1_DSN P2_DSN
"""
import os
import signal
import subprocess
import sys
import threading
import time

import psycopg2

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
import doom_sql as sql  # noqa: E402

ADMIN, P1, P2 = sys.argv[1], sys.argv[2], sys.argv[3]
TIMER_TICS = 1400          # 40 s: long enough to see an item respawn first
INTERMISSION = 3


def bot(dsn, stop, out):
    sql.API_MODE = True
    c = psycopg2.connect(dsn); c.autocommit = True; k = c.cursor(); sql.prepare_client(k)
    me = None
    while me is None and not stop.is_set():
        me = sql.api_join(k); time.sleep(0.2)
    frames = {}; empties = 0; errors = 0; last_map = None
    while not stop.is_set():
        try:
            k.execute("SELECT map_id, map_name, state FROM api_match"); map_id, name, state = k.fetchone()
            if name != last_map:
                out.append(f"    {dsn.split()[1]} sees {name} ({state})"); last_map = name
            sql.mp_push_input(k, map_id, me, (3, 0.0, 0.0, False, 3.0, False, None, False))
            cam = sql.camera_pose(k, map_id, me, 0.5) or sql.player_pose(k, map_id, me)
            if cam is None:
                time.sleep(0.05); continue
            # render_frame's api_pose call is also the heartbeat that keeps the slot
            frame = sql.render_frame(k, map_id, me, 3, cam[:4])
            frames[name] = frames.get(name, 0) + 1
        except ValueError:
            empties += 1; time.sleep(0.1)          # the frame view is being rebuilt
        except Exception as exc:  # noqa: BLE001
            errors += 1; c.rollback(); time.sleep(0.1)
            if errors <= 2: out.append(f"    bot error: {str(exc).splitlines()[0][:100]}")
    out.append(f"    {dsn.split()[1]}: frames per map {frames}, {empties} empty, {errors} errors")
    out.append(("ok", all(v > 20 for v in frames.values()) and len(frames) >= 2 and errors == 0))


def main():
    env = dict(os.environ, DB_DSN=ADMIN, MAP_ID="1", SKILL="3", IDLE_SECONDS="5", TIMER_TICS=str(TIMER_TICS),
               INTERMISSION_SECONDS=str(INTERMISSION), ROTATION="E1M1,E1M2", MONSTERS="1", ALTDEATH="1")
    ref = subprocess.Popen([sys.executable, os.path.join(REPO, "doom_server.py")], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = []
    def pump():
        for line in ref.stdout:
            lines.append(line.rstrip())
    threading.Thread(target=pump, daemon=True).start()
    deadline = time.time() + 120
    while time.time() < deadline and not any("ready in" in l for l in lines):
        if ref.poll() is not None:
            print("\n".join(lines)); return 1
        time.sleep(0.2)
    print("  referee: " + next((l for l in lines if "match:" in l), "?"))
    a = psycopg2.connect(ADMIN); a.autocommit = True; ka = a.cursor()
    bad = 0
    def check(cond, what):
        nonlocal bad
        bad += 0 if cond else 1
        print(f"  {'ok ' if cond else 'BAD'} {what}")

    stop = threading.Event(); out = []
    bots = [threading.Thread(target=bot, args=(d, stop, out), daemon=True) for d in (P1, P2)]
    for b in bots: b.start()
    time.sleep(6)
    ka.execute("SELECT slot, role_name FROM mp_players WHERE role_name IS NOT NULL ORDER BY slot"); held0 = ka.fetchall()
    check(len(held0) == 2, f"two slots held: {held0}")
    ka.execute("SELECT count(*) FROM thing_health h JOIN things t ON t.map_id=h.map_id AND t.id=h.thing_id "
               "JOIN thing_combat_defs d ON d.thing_type=t.type AND d.counts_kill WHERE h.map_id=1 AND h.alive")
    check(ka.fetchone()[0] > 0, "monsters are in (MONSTERS=1)")
    # -altdeath: take an item by hand and watch it come back
    ka.execute("SELECT t.id FROM things t JOIN pickup_defs d ON d.thing_type=t.type WHERE t.map_id=1 "
               "AND NOT EXISTS (SELECT 1 FROM picked_up_items pu WHERE pu.map_id=t.map_id AND pu.thing_id=t.id) ORDER BY t.id LIMIT 1")
    item = ka.fetchone()[0]
    ka.execute("INSERT INTO picked_up_items (map_id, thing_id) VALUES (1, %s)", (item,))
    time.sleep(0.5)
    ka.execute("SELECT respawn_tic FROM item_respawns WHERE map_id=1 AND thing_id=%s", (item,)); q = ka.fetchone()
    check(q is not None, f"item {item} queued for respawn at tic {q and q[0]}")
    t_take = time.time()
    back = None
    fog = 0
    while time.time() - t_take < 40:
        ka.execute("SELECT NOT EXISTS (SELECT 1 FROM picked_up_items WHERE map_id=1 AND thing_id=%s), "
                   "(SELECT count(*) FROM world_effects WHERE map_id=1 AND effect_type='ifog')", (item,))
        gone, fog_now = ka.fetchone(); fog = max(fog, fog_now)
        if gone:
            back = time.time() - t_take; break
        time.sleep(0.1)
    check(back is not None and 28 <= back <= 36, f"item back after {back and round(back, 1)} s (vanilla: 30)")
    ka.execute("SELECT count(*) FROM sound_events WHERE map_id=1 AND event_key LIKE 'itemrespawn:%%'")
    check(ka.fetchone()[0] >= 1, "DSITMBK cued for the respawn")
    for _ in range(12):
        ka.execute("SELECT count(*) FROM world_effects WHERE map_id=1 AND effect_type='ifog'")
        fog = max(fog, ka.fetchone()[0]); time.sleep(0.05)
    check(fog >= 1, f"item fog effect seen ({fog})")
    # the timer
    t0 = time.time(); seen = []
    while time.time() - t0 < 60:
        ka.execute("SELECT state, map_id FROM mp_match"); st = ka.fetchone()
        if not seen or seen[-1][1:] != st: seen.append((round(time.time() - t0, 1),) + tuple(st))
        if st[0] == 'playing' and st[1] != 1: break
        time.sleep(0.2)
    print(f"    match states seen: {seen}")
    check(any(s[1] == 'intermission' for s in seen), "intermission ran")
    check(seen[-1][1] == 'playing' and seen[-1][2] != 1, f"rotated to map {seen[-1][2]}")
    ka.execute("SELECT slot, role_name FROM mp_players WHERE role_name IS NOT NULL ORDER BY slot"); held1 = ka.fetchall()
    check(held1 == held0, f"same players hold the same slots: {held1}")
    time.sleep(8)
    ka.execute("SELECT mp.slot, ps.frags, ps.alive, ps.level_tics FROM mp_players mp JOIN player_state ps ON ps.map_id=mp.map_id "
               "AND ps.player_thing_id=mp.player_thing_id WHERE mp.role_name IS NOT NULL ORDER BY mp.slot")
    rows = ka.fetchall()
    check(all(r[2] for r in rows), f"players respawned on the new map: {rows}")
    check(all(r[1] == 0 for r in rows), "frags start at zero")
    stop.set()
    for b in bots: b.join(10)
    for line in out:
        if isinstance(line, str): print(line)
    check(all(v for k, v in (o for o in out if isinstance(o, tuple))), "bots rendered on both maps without errors")
    ref.send_signal(signal.SIGINT)
    try:
        ref.wait(15)
    except subprocess.TimeoutExpired:
        check(False, "referee did not stop on SIGINT within 15 s"); ref.kill(); ref.wait()
    errs = [l for l in lines if "dropped a tic" in l or "Traceback" in l]
    check(not errs, f"referee log clean ({len(errs)} problems)" + ("" if not errs else ": " + errs[0][:120]))
    for l in lines:
        if "level ended" in l or "now on map" in l: print("    " + l)
    print("ROTATION OK" if not bad else f"ROTATION: {bad} problems")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
