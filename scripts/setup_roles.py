#!/usr/bin/env python3
"""Provision the two default deathmatch player roles, doom_player1/2.

A convenience over scripts/add_player.py, which provisions any number of
players by name. Each player connects as its own role with no table grants:
the api_* functions and views (sql/runtime/functions/42_api.sql,
cedarscript_runtime.install_api_views) are everything it can touch, and each
resolves the caller from session_user. Run as the database owner after every
fresh import (roles live in the database). Passwords come from
DOOM_PLAYER1_PASSWORD / DOOM_PLAYER2_PASSWORD or are generated and printed once.

    python3 scripts/setup_roles.py "<admin dsn>"
"""
import os
import secrets
import string
import sys

import psycopg2

sys.path.insert(0, __file__.rsplit("/", 2)[0])
from cedarscript_runtime import grant_player_api  # noqa: E402

ROLES = ("doom_player1", "doom_player2")


def strong_password():
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(20)) + "-Dm1!"


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    conn = psycopg2.connect(sys.argv[1])
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SELECT current_setting('server_version')")
    for index, role in enumerate(ROLES, 1):
        password = os.getenv(f"DOOM_PLAYER{index}_PASSWORD") or strong_password()
        cur.execute("SELECT count(*) FROM pg_roles WHERE rolname=%s", (role,))
        exists = cur.fetchone()[0] > 0
        verb = "ALTER" if exists else "CREATE"
        cur.execute(f"{verb} ROLE {role} LOGIN PASSWORD %s", (password,))
        grant_player_api(cur, role)
        print(f"{'updated' if exists else 'created'} {role}")
        print(f"  DB_DSN=\"dbname=postgres user={role} password={password} "
              f"host=<server> port=<port>\" DOOM_JOIN={index} python3 doom_client.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
