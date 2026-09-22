#!/usr/bin/env python3
"""Provision one player: a database role with exactly the player API granted.

    python3 scripts/add_player.py "<owner dsn>" <username> [password]

Any number of players may exist; the referee's four slots go to whoever calls
api_join first, and are handed back when a player goes silent. Without a
password one is generated and printed once. Re-running updates the password
and refreshes the grants. Roles live in the database: run this again after a
fresh import.
"""
import os
import secrets
import string
import sys

import psycopg2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cedarscript_runtime import grant_player_api  # noqa: E402


def strong_password():
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(20)) + "-Dm1!"


def add_player(cur, role, password):
    if not role.replace("_", "").isalnum() or not role[0].isalpha():
        raise SystemExit(f"role names are letters, digits and _ : {role!r}")
    cur.execute("SELECT count(*) FROM pg_roles WHERE rolname=%s", (role,))
    exists = cur.fetchone()[0] > 0
    cur.execute(f"{'ALTER' if exists else 'CREATE'} ROLE {role} LOGIN PASSWORD %s", (password,))
    grant_player_api(cur, role)
    return exists


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    dsn, role = sys.argv[1], sys.argv[2]
    password = sys.argv[3] if len(sys.argv) > 3 else strong_password()
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    existed = add_player(conn.cursor(), role, password)
    print(f"{'updated' if existed else 'created'} {role}")
    print(f"  browser: user {role}, password {password}")
    print(f"  native:  DB_DSN='dbname=postgres user={role} password={password} "
          f"host=<server> port=<port>' DOOM_JOIN=1 python3 doom_client.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
