#!/usr/bin/env python3
"""Restart the stack when CedarDB stops answering, not just when it dies.

`Restart=on-failure` catches the segfault: the process is gone, systemd brings
it back in three seconds. It does not catch the other failure mode, where the
process stays alive with its worker threads spinning and no statement is ever
scheduled again. That one cost 28 hours of downtime, because from systemd's
side nothing was wrong.

So the check has to be a real query, and its deadline has to be enforced from
outside the client: when the server is wedged a connection still authenticates
in milliseconds, `SELECT 1` never returns, and `statement_timeout` never fires
because the session is never scheduled at all. A libpq call in this state
blocks forever and would take the watchdog down with it, so every probe runs in
a subprocess that gets killed on the deadline -- which also drops its socket
rather than leaving another hung session against the role's connection limit.

    DB_DSN=... python3 scripts/db_watchdog.py

Knobs (environment, all optional): WATCHDOG_INTERVAL seconds between probes,
WATCHDOG_TIMEOUT probe deadline, WATCHDOG_FAILURES consecutive failures before
acting, WATCHDOG_COOLDOWN minimum seconds between restarts, WATCHDOG_UNITS the
units to restart after the database, WATCHDOG_GRACE how long to wait after a
restart before probing again.
"""
import os
import subprocess
import sys
import time

INTERVAL = float(os.environ.get("WATCHDOG_INTERVAL", "15"))
TIMEOUT = float(os.environ.get("WATCHDOG_TIMEOUT", "10"))
FAILURES = int(os.environ.get("WATCHDOG_FAILURES", "4"))
COOLDOWN = float(os.environ.get("WATCHDOG_COOLDOWN", "300"))
GRACE = float(os.environ.get("WATCHDOG_GRACE", "60"))
UNITS = os.environ.get("WATCHDOG_UNITS", "doom-referee doom-explorer doom-bots").split()
DB_UNIT = os.environ.get("WATCHDOG_DB_UNIT", "doom-db")

PROBE = """
import os, sys, psycopg2
c = psycopg2.connect(os.environ["DB_DSN"] + " connect_timeout=5")
c.autocommit = True
k = c.cursor()
k.execute("SELECT 1")
sys.exit(0 if k.fetchone() == (1,) else 1)
"""


def log(message):
    print(f"[watchdog {time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)


def probe():
    """One `SELECT 1`, killed from outside if it does not come back in time."""
    try:
        done = subprocess.run([sys.executable, "-c", PROBE], timeout=TIMEOUT,
                              capture_output=True, text=True)
    except subprocess.TimeoutExpired:
        return False, f"no answer in {TIMEOUT:.0f}s"
    if done.returncode == 0:
        return True, ""
    return False, (done.stderr.strip().splitlines() or ["exit %d" % done.returncode])[-1][:120]


def systemctl(*args):
    done = subprocess.run(["systemctl", "--user", *args], capture_output=True, text=True)
    if done.returncode != 0:
        log(f"  systemctl {' '.join(args)} failed: {done.stderr.strip()[:120]}")
    return done.returncode == 0


def restart():
    """The database first, then everything that holds a connection to it."""
    log(f"restarting {DB_UNIT}")
    systemctl("restart", DB_UNIT)
    # Wait for it to answer before the dependents reconnect, but do not block
    # forever if the fresh process is wedged too -- the next cycle handles that.
    deadline = time.time() + 120
    while time.time() < deadline:
        ok, _ = probe()
        if ok:
            log(f"  {DB_UNIT} answering again")
            break
        time.sleep(3)
    else:
        log(f"  {DB_UNIT} still not answering after 120s; restarting dependents anyway")
    if UNITS:
        log(f"restarting {' '.join(UNITS)}")
        systemctl("restart", *UNITS)


def main():
    if not os.environ.get("DB_DSN"):
        sys.exit("set DB_DSN")
    log(f"watching {DB_UNIT}: SELECT 1 every {INTERVAL:.0f}s, "
        f"{TIMEOUT:.0f}s deadline, {FAILURES} strikes, {COOLDOWN:.0f}s cooldown")
    consecutive = 0
    last_restart = 0.0
    while True:
        ok, why = probe()
        if ok:
            if consecutive:
                log(f"answering again after {consecutive} failed probe(s)")
            consecutive = 0
        else:
            consecutive += 1
            log(f"probe failed ({consecutive}/{FAILURES}): {why}")
            if consecutive >= FAILURES:
                since = time.time() - last_restart
                if since < COOLDOWN:
                    log(f"  in cooldown, {COOLDOWN - since:.0f}s left; not restarting")
                else:
                    restart()
                    last_restart = time.time()
                    consecutive = 0
                    time.sleep(GRACE)
                    continue
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
