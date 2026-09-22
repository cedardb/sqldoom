#!/usr/bin/env python3
"""Deathmatch referee

Connects as the database owner, opens a match on MAP_ID with four free slots,
installs the per-slot frame views, and runs doom_run_mp_tic at 35 Hz.

    DB_DSN="<owner dsn>" MAP_ID=1 SKILL=2 python3 doom_server.py
    # a player, native:   DB_DSN="user=<role> ..." DOOM_JOIN=1 python3 doom_client.py
    # a player, browser:  python3 doom_web.py, then open the page it prints

The match runs like a 1990s server. Config parameters set via ENV and their default:
    SKILL 2 (the engine's skill_t, 0 to 4: 0 "I'm too young to die", 1 "Hey,
             not too rough", 2 "Hurt me plenty", 3 "Ultra-Violence", 4 "Nightmare!";
             the same numbering the single-player client and the SQL use)
    ALTDEATH 1 (items respawn after 30 s),
    TIMER_MINUTES 10  (level ends after 10 minutes, loops to next level in sequence),
    INTERMISSION_SECONDS 10 (break between levels)
    MONSTERS 1 (monsters appear as well)
    RESPAWN_MONSTERS 1 (monsters respawn as with vanilla -respawn: 12 s at the
             least, then a 5-in-256 roll every 32 tics, about a minute on average)
"""
import os
import signal
import sys
import time

import psycopg2

import doom_sql as sql
from cedarscript_runtime import install_match_frame_views
import doom_config
from doom_config import DB_DSN, REPLAN_MS, load_constants, tune_replanning


def log(message):
    print(message, flush=True)


def where_it_failed(exc):
    """The parts of a database error that say which statement raised it."""
    diag = getattr(exc, "diag", None)
    if diag is None:
        return ""
    parts = [f"{label}: " + " ".join(value.split())[:300]
             for label, value in (("detail", diag.message_detail),
                                  ("context", diag.context),
                                  ("query", diag.internal_query))
             if value]
    return "".join("\n[server]     " + part for part in parts)


MAP_ID = int(os.getenv("MAP_ID", 1))
START_MAP_ID = MAP_ID
SKILL = int(os.getenv("SKILL", 2))
IDLE_SECONDS = int(os.getenv("IDLE_SECONDS", 5))
TIMER_TICS = int(os.getenv("TIMER_TICS", int(float(os.getenv("TIMER_MINUTES", 10)) * 60 * 35)))
ROTATION = [m.strip().upper() for m in os.getenv("ROTATION", "E1M1,E1M2,E1M3,E1M4,E1M5,E1M6,E1M7").split(",") if m.strip()]
ALTDEATH = os.getenv("ALTDEATH", "1") == "1"
MONSTERS = os.getenv("MONSTERS", "1") == "1"
RESPAWN_MONSTERS = os.getenv("RESPAWN_MONSTERS", "1") == "1"
INTERMISSION_SECONDS = float(os.getenv("INTERMISSION_SECONDS", 10))
# How long one player may keep a seat while others are waiting in the lobby
# (0: forever). Nobody is asked to leave an empty room.
HOLD_SECONDS = int(float(os.getenv("HOLD_MINUTES", 15)) * 60)
MATCH_KEY = 0
STOPPING = False

def _terminate(*_):
    global STOPPING
    STOPPING = True


def main():
    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)
    conn = psycopg2.connect(DB_DSN)
    conn.autocommit = True
    cur = conn.cursor()
    if sql.set_session_parallel(cur, os.getenv("DB_PARALLEL", "")):
        log(f"[server] tic runs with max_parallel_workers={os.getenv('DB_PARALLEL')}")
    if sql.set_session_async_commit(cur):
        log("[server] tic commits asynchronously (no fsync per tic)")
    tune_replanning(cur)
    load_constants(cur)
    if REPLAN_MS > 0:
        log(f"[server] replan interval set to {REPLAN_MS / 1000:.0f} s server-wide (REPLAN_MS)")
    sql.prepare_client(cur)
    cur.execute("SELECT doom_mp_referee_claim(%s, 3)", (MATCH_KEY,))
    if not cur.fetchone()[0]:
        raise SystemExit("another referee is running the match (heartbeat within 3 s); "
                         " Stop it first, or wait 3 s if it just died.")
    cur.execute("DELETE FROM mp_inputs")
    cur.execute("SELECT doom_mp_configure(%s,%s,%s,%s,%s,%s,%s)",
                (MAP_ID, SKILL, TIMER_TICS, ALTDEATH, MONSTERS, RESPAWN_MONSTERS,
                 int(INTERMISSION_SECONDS * 35)))
    cur.execute("UPDATE mp_match SET hold_seconds = %s", (HOLD_SECONDS,))
    cur.execute("SELECT name FROM maps")
    loaded = {row[0] for row in cur.fetchall()}
    rotation = [m for m in ROTATION if m in loaded]
    for m in ROTATION:
        if m not in loaded:
            log(f"[server] rotation: {m} is not loaded, skipped")
    cur.execute("DELETE FROM mp_rotation")
    for position, name in enumerate(rotation):
        cur.execute("INSERT INTO mp_rotation (position, map_name) VALUES (%s, %s)", (position, name))
    log("[server] match: " + ", ".join([
        f"timer {TIMER_TICS / 35 / 60:.1f} min" if TIMER_TICS else "no timer",
        "altdeath" if ALTDEATH else "deathmatch 1.0",
        "monsters" + (" respawning" if RESPAWN_MONSTERS else "") if MONSTERS else "nomonsters",
        "rotation " + (" > ".join(rotation) if rotation else "none"),
        f"intermission {INTERMISSION_SECONDS:g} s",
        f"a seat is {HOLD_SECONDS / 60:g} min while others wait" if HOLD_SECONDS else "no seat limit"]))

    # Clients that outlived a previous referee keep calling api_join and
    # api_camera while this one opens the match, and their writes to
    # mp_players collide with ours. Opening a match is idempotent, so a lost
    # race is simply tried again.
    for attempt in range(30):
        try:
            players = sql.mp_start(cur, MAP_ID, SKILL)
            if not {1, 2} <= set(players):
                raise SystemExit(f"map {MAP_ID} has no player 1 and player 2 starts")
            cur.execute("SELECT map_id FROM maps WHERE name = ANY(%s) OR map_id = %s ORDER BY map_id",
                        (rotation, MAP_ID))
            match_maps = [row[0] for row in cur.fetchall()]
            install_match_frame_views(cur, match_maps, SKILL)
            break
        except psycopg2.errors.SerializationFailure:
            conn.rollback()
            time.sleep(0.2)
    else:
        raise SystemExit("could not open the match: clients kept writing the slot table")

    log(f"[server] deathmatch on map {MAP_ID}, skill {SKILL}: "
        + ", ".join(f"slot {slot} = thing {thing}" for slot, thing in sorted(players.items()))
        + "; all free")
    log("[server] compiling the tic (the first one takes a few seconds)...")
    started = time.perf_counter()
    for attempt in range(30):
        try:
            sql.mp_tic(cur, MAP_ID, SKILL, players)
            # Warm the join path too
            cur.execute("SELECT doom_mp_request_all(%s)", (MAP_ID,))
            sql.mp_tic(cur, MAP_ID, SKILL, players)
            cur.execute("SELECT doom_mp_vacate_all(%s)", (MAP_ID,))
            break
        except psycopg2.errors.SerializationFailure:
            conn.rollback()
            time.sleep(0.2)
    cur.execute("SELECT doom_mp_open()")
    log(f"[server] ready in {time.perf_counter() - started:.1f} s; players join "
        f"from the browser (doom_web.py) or with DOOM_JOIN=1 python3 doom_client.py")

    next_tic = time.perf_counter()
    last_report = next_tic
    last_reap = next_tic
    tic_times = []
    report_at = [time.perf_counter()]
    tic_stats_ok = [True]

    holders = {}
    dropped = 0
    drop_reasons = {}
    housekeeping_error = [None]

    def housekeeping():
        """Once a second: heartbeat, reap, and log who came and went."""
        nonlocal last_reap
        if time.perf_counter() - last_reap >= 1.0:
            last_reap = time.perf_counter()
            # A reap can lose a race with a player's own api call on the same row
            try:
                cur.execute("SELECT doom_mp_referee_beat(%s)", (MATCH_KEY,))
                freed = sql.mp_reap(cur, MAP_ID, IDLE_SECONDS)
                # Fair play: a seat held past HOLD_SECONDS goes to the lobby,
                # but only while somebody is actually waiting there.
                turned = []
                if HOLD_SECONDS:
                    overdue = ("mp.map_id = %s AND mp.role_name IS NOT NULL "
                               "AND mp.claimed_at < now() - (%s * interval '1 second') "
                               "AND EXISTS (SELECT 1 FROM mp_waiting w "
                               "            WHERE EXTRACT(EPOCH FROM (now() - w.last_seen)) <= 5)")
                    cur.execute(f"SELECT mp.slot, mp.role_name FROM mp_players mp WHERE {overdue}",
                                (MAP_ID, HOLD_SECONDS))
                    turned = cur.fetchall()
                    if turned:
                        cur.execute("UPDATE mp_players mp SET role_name = NULL, display_name = NULL, "
                                    f"claimed_at = NULL WHERE {overdue}", (MAP_ID, HOLD_SECONDS))
                for slot, role in turned:
                    log(f"[server] slot {slot} turn over: {role} had it {HOLD_SECONDS / 60:g} min "
                        "and someone is waiting")
            except psycopg2.Error as exc:
                conn.rollback()
                reason = str(exc).splitlines()[0]
                if reason != housekeeping_error[0]:
                    housekeeping_error[0] = reason
                    log(f"[server] housekeeping skipped once: {reason}")
                return
            cur.execute("SELECT mp.slot, mp.role_name, mp.display_name, ps.frags FROM mp_players mp "
                        "JOIN player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id "
                        "WHERE mp.map_id = %s ORDER BY mp.slot", (MAP_ID,))
            now = {slot: (role, name, frags) for slot, role, name, frags in cur.fetchall()}
            for slot, (role, name, frags) in now.items():
                was = holders.get(slot, (None, None, 0))[0]
                if role and not was:
                    log(f"[server] slot {slot} claimed by {role}" + (f' "{name}"' if name else ""))
                elif was and not role:
                    log(f"[server] slot {slot} freed ({was}, {holders[slot][2]} frags"
                        + (", idle" if freed else "") + ")")
                elif role and name and name != holders.get(slot, (None, None))[1]:
                    log(f'[server] slot {slot} {role} is now "{name}"')
            holders.clear(); holders.update(now)

    def report():
        """Every five seconds: the tic's cost, and the world from mp_stats."""
        nonlocal dropped
        tic_times.sort()
        med = tic_times[len(tic_times) // 2] * 1000 if tic_times else 0
        p90 = tic_times[int(len(tic_times) * 0.9)] * 1000 if tic_times else 0
        mx = tic_times[-1] * 1000 if tic_times else 0
        cur.execute("SELECT map_name, state, timer_tics, level_tics, monsters_alive, monsters_total, monsters_awake, "
                    "projectiles, effects, items_out, items_queued, movers, input_backlog, sound_rows, sessions, maps_played, waiting "
                    "FROM mp_stats")
        st = cur.fetchone()
        clock = ""
        if st:
            left = (st[2] - st[3]) / 35 if st[2] > 0 else None
            clock = (f"{st[0]} {st[1]} " + (f"{int(left // 60)}:{int(left % 60):02d} left" if left is not None else f"{st[3] / 35:.0f} s")
                     + f" (map {st[15] + 1} of the run)")
        log(f"[server] {clock} | tic {med:.1f} ms p90 {p90:.1f} max {mx:.1f}, {len(tic_times)} tics, {dropped} dropped"
            + ("" if not drop_reasons else " (" + "; ".join(f"{n}x {r[:70]}" for r, n in drop_reasons.items()) + ")")
            + (f" | monsters {st[4]}/{st[5]} awake {st[6]} | projectiles {st[7]} effects {st[8]} movers {st[11]}"
               f" | items out {st[9]} queued {st[10]} | inputs waiting {st[12]} sounds {st[13]} | db sessions {st[14]} | lobby {st[16]}" if st else ""))
        score = sql.mp_score(cur, MAP_ID)
        log("[server]   " + "  ".join(
            f"P{slot}[{role or 'free'}]: {frags} frags, {health} hp{'' if alive else ' (dead)'}"
            for slot, frags, health, alive, role in score))
        # The same numbers to SQL for the console's tic sparkline: a client
        # round trip is not the server's tic and must not be drawn as one.
        # Outside the tic function on purpose -- reset_stage does not restore
        # this table and determinism must not depend on it.
        now_t = time.perf_counter()
        interval, report_at[0] = now_t - report_at[0], now_t
        if tic_stats_ok[0]:
            try:
                cur.execute(
                    "INSERT INTO api_tic_stats (id, updated_at, tic_ms, tic_p90_ms, tic_max_ms, "
                    "tics, dropped, interval_seconds) VALUES (1, now(), %s, %s, %s, %s, %s, %s) "
                    "ON CONFLICT (id) DO UPDATE SET updated_at = EXCLUDED.updated_at, "
                    "tic_ms = EXCLUDED.tic_ms, tic_p90_ms = EXCLUDED.tic_p90_ms, "
                    "tic_max_ms = EXCLUDED.tic_max_ms, tics = EXCLUDED.tics, "
                    "dropped = EXCLUDED.dropped, interval_seconds = EXCLUDED.interval_seconds",
                    (med, p90, mx, len(tic_times), dropped, interval))
            except psycopg2.Error as exc:
                tic_stats_ok[0] = False
                log("[server] api_tic_stats unavailable, not publishing tic cost: "
                    + str(exc).splitlines()[0][:100])
        tic_times.clear()
        dropped = 0
        drop_reasons.clear()

    def rotate():
        """The intermission, then the next map: the world stands still while
        the frag table is up, and whoever held a slot keeps it."""
        global MAP_ID
        nonlocal players, next_tic
        score = sql.mp_score(cur, MAP_ID)
        log("[server] level ended on map " + str(MAP_ID) + ": "
            + "  ".join(f"P{slot}[{role or 'free'}] {frags}" for slot, frags, health, alive, role in score))
        cur.execute("SELECT doom_mp_intermission_begin()")
        cur.execute("SELECT state FROM mp_match")
        if cur.fetchone()[0] != 'intermission':
            log("[server] the match row did not take the intermission; setting it again")
            cur.execute("SELECT doom_mp_intermission_begin()")
        deadline = time.perf_counter() + INTERMISSION_SECONDS + 20
        while not STOPPING:
            housekeeping()
            cur.execute("SELECT doom_mp_intermission_over()")
            if cur.fetchone()[0]:
                break
            if time.perf_counter() > deadline:
                log("[server] intermission never ended on the clock; moving on")
                break
            time.sleep(0.1)
        if STOPPING:
            return
        for attempt in range(30):
            try:
                cur.execute("SELECT doom_mp_rotate()")
                MAP_ID = int(cur.fetchone()[0])
                players = sql.mp_players(cur, MAP_ID)
                break
            except psycopg2.Error as exc:
                conn.rollback()
                if not isinstance(exc, psycopg2.errors.SerializationFailure):
                    log("[server] rotate failed, retrying: " + " | ".join(str(exc).splitlines()[:2]))
                time.sleep(0.2 if attempt < 10 else 1.0)
        else:
            log("[server] could not move the match on; reopening it on the start map")
            for attempt in range(30):
                try:
                    players = sql.mp_start(cur, START_MAP_ID, SKILL)
                    cur.execute("UPDATE mp_match SET map_id = %s, state = 'playing', intermission_until = NULL", (START_MAP_ID,))
                    MAP_ID = START_MAP_ID
                    break
                except psycopg2.Error:
                    conn.rollback()
                    time.sleep(1.0)
        if 1 not in players:
            log(f"[server] map {MAP_ID} had no slots after the rotation; opening it")
            for attempt in range(30):
                try:
                    players = sql.mp_start(cur, MAP_ID, SKILL)
                    break
                except psycopg2.Error:
                    conn.rollback()
                    time.sleep(0.2 if attempt < 10 else 1.0)
            else:
                log(f"[server] could not open map {MAP_ID}; falling back to the start map")
                MAP_ID = START_MAP_ID
                players = sql.mp_start(cur, START_MAP_ID, SKILL)

        cur.execute("SELECT state, map_id FROM mp_match")
        state, shown = cur.fetchone()
        if state != 'playing' or shown != MAP_ID:
            log(f"[server] the match row did not follow the rotation (state {state}, map {shown}); setting it to map {MAP_ID}")
            cur.execute("UPDATE mp_match SET map_id = %s, state = 'playing', intermission_until = NULL, maps_played = maps_played + 1", (MAP_ID,))
            cur.execute("DELETE FROM mp_inputs WHERE map_id <> %s", (MAP_ID,))
        cur.execute("SELECT count(*) FROM mp_players WHERE map_id=%s AND role_name IS NOT NULL", (MAP_ID,))
        held = cur.fetchone()[0]
        log(f"[server] now on map {MAP_ID}: " + ", ".join(f"slot {s} = thing {t}" for s, t in sorted(players.items()))
            + f"; {held} slot(s) carried over")
        next_tic = time.perf_counter()

    try:
        while not STOPPING:
            t0 = time.perf_counter()
            level_done = False
            if 1 not in players:
                log(f"[server] map {MAP_ID} lost its slot rows; reopening")
                try:
                    players = sql.mp_start(cur, MAP_ID, SKILL)
                except psycopg2.Error:
                    conn.rollback()
                time.sleep(doom_config.TIC_SECONDS)
                continue
            try:
                level_done = sql.mp_tic(cur, MAP_ID, SKILL, players)
            except psycopg2.Error as exc:
                conn.rollback()
                dropped += 1
                reason = " | ".join(str(exc).splitlines()[:2])
                if reason not in drop_reasons:
                    log("[server] dropped a tic: " + reason + where_it_failed(exc))
                drop_reasons[reason] = drop_reasons.get(reason, 0) + 1
                try:
                    cur.execute("DELETE FROM mp_inputs WHERE map_id=%s", (MAP_ID,))
                except psycopg2.Error:
                    conn.rollback()
            tic_times.append(time.perf_counter() - t0)
            if level_done:
                rotate()
                continue
            next_tic += doom_config.TIC_SECONDS
            delay = next_tic - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            elif delay < -0.5:
                # Fell far behind (a stall, a debugger); do not try to catch up.
                next_tic = time.perf_counter()
            housekeeping()
            if time.perf_counter() - last_report >= 5.0:
                last_report = time.perf_counter()
                report()
    except KeyboardInterrupt:
        pass
    try:
        cur.execute("SELECT doom_mp_referee_release(%s)", (MATCH_KEY,))
    except psycopg2.Error:
        pass
    log("[server] stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
