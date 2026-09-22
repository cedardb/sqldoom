#!/usr/bin/env python3
"""Provision a read-only spectator: the login the cloud demo's query console
(a db-explorer) uses against the match database.

    python3 scripts/add_spectator.py "<owner dsn>" [username] [password]

The role gets SELECT on the WAD tables, the catalogues, the match's public
views and the tic's trace (cedarscript_runtime.SPECTATOR_RELATIONS) and
nothing else: no api_* function, no sequence, no frame view, and none of the
tables that say where a live player stands. It is remembered in
api_spectator_roles so a runtime reinstall re-grants it. Re-running updates
the password and refreshes the grants.

The password is letters and digits only, so it can sit unescaped in the
postgresql:// URL the explorer takes. Two settings are best-effort, because
not every CedarDB build has them: a connection limit (the explorer's pool is
small anyway) and a per-role max_parallel_workers, so a public query cannot
take the renderers' cores.
"""
import os
import secrets
import string
import sys

import psycopg2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cedarscript_runtime import grant_spectator_api  # noqa: E402

DEFAULT_ROLE = "doom_spectator"
# The explorer opens a pool, not a session, and a limit of 4 refused visitors
# outright (78 "too many connections for role" in one afternoon). The cap is
# there so a public console cannot exhaust the server, not to size the pool:
# keep it well under max_connections and let the query timeouts do the rest.
CONNECTION_LIMIT = 16
PARALLEL_WORKERS = 2


def strong_password():
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(28))


def add_spectator(cur, role, password):
    if not role.replace("_", "").isalnum() or not role[0].isalpha():
        raise SystemExit(f"role names are letters, digits and _ : {role!r}")
    cur.execute("SELECT count(*) FROM pg_roles WHERE rolname=%s", (role,))
    exists = cur.fetchone()[0] > 0
    cur.execute(f"{'ALTER' if exists else 'CREATE'} ROLE {role} LOGIN PASSWORD %s", (password,))
    granted = grant_spectator_api(cur, role)
    notes = []
    for label, statement in (
        ("connection limit", f"ALTER ROLE {role} CONNECTION LIMIT {CONNECTION_LIMIT}"),
        ("max_parallel_workers", f"ALTER ROLE {role} SET max_parallel_workers = {PARALLEL_WORKERS}"),
    ):
        try:
            cur.execute(statement)
        except psycopg2.Error as exc:
            notes.append(f"{label} not applied: {str(exc).strip().splitlines()[0]}")
    return exists, granted, notes


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    dsn = sys.argv[1]
    role = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_ROLE
    password = sys.argv[3] if len(sys.argv) > 3 else strong_password()
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    existed, granted, notes = add_spectator(conn.cursor(), role, password)
    print(f"{'updated' if existed else 'created'} {role}: SELECT on {len(granted)} relations")
    for note in notes:
        print(f"  note: {note}")
    print(f"  explorer: user {role}, password {password}")
    print(f"  CEDARDB_URL=postgresql://{role}:{password}@127.0.0.1:<port>/postgres")
    return 0


if __name__ == "__main__":
    sys.exit(main())
