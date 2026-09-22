#!/usr/bin/env bash
# The whole SQLDOOM cloud-demo stack on one machine, for trying the
# integration before anything is deployed:
#
#   a fresh CedarDB with the WAD, the runtime, players, guests and the
#   spectator role          127.0.0.1:$DB_PORT      (data in ./local_demo/db)
#   the 35 Hz referee        doom_server.py
#   the page and tunnel      http://127.0.0.1:$WEB_PORT/
#   the spectator's explorer http://127.0.0.1:$EXPLORER_PORT/api/query (docker)
#   BOTS bot players (1)     scripts/bots.mjs, through the relay like anyone
#   the cloud frontend       http://localhost:$FRONTEND_PORT/  (vite, mock fleet,
#                            no sign-in, the Doom project on)
#
#   scripts/local_demo.sh            start everything (reuses the database once created)
#   scripts/local_demo.sh stop       stop everything (the database directory stays)
#   scripts/local_demo.sh status     what is running
#   scripts/local_demo.sh check      run scripts/spectator_check.py against the running database
#   scripts/local_demo.sh sql "…"    run one statement as the owner and print the rows
#   scripts/local_demo.sh reset      stop, then delete ./local_demo so the next start rebuilds
#   scripts/local_demo.sh frontend   only the cloud frontend, against remote game hosts
#                                    configured with DOOM_HOSTS
#
# Everything lives under ./local_demo (the owner password in env, mode 600;
# guest and spectator logins; pid files; logs/). Override the knobs below in
# the environment, e.g. SKILL=2 MONSTERS=0 scripts/local_demo.sh for a match
# without monsters. The retail WAD is fine here: nothing leaves the machine.
set -euo pipefail

APP=$(cd "$(dirname "$0")/.." && pwd)
# A second stack next to the first (other ports, other state): DOOM_LOCAL_STATE=/elsewhere.
STATE=${DOOM_LOCAL_STATE:-$APP/local_demo}
# Machine-specific paths and images come from ./local_demo.env (not committed):
#   FRONTEND_DIR=/path/to/cedardb-cloud-frontend          (always)
#   CEDARDB_BIN=/path/to/cedardb                          (start: the local stack)
#   EXPLORER_IMAGE=<registry>/internal/db-explorer:latest (start)
#   DOOM_HOSTS=eu=http://1.2.3.4@eu-central-1             (frontend: deployed hosts)
#   DOOM_INSTANCE_TYPE=c1-16                              (optional: the tier shown; a fleet id, not an EC2 name)
#   DOOM_DEMO_ENDS=2026-10-15                             (optional: the limited-time date)
# Like the frontend's own deploy, the script maps these to the VITE_* build variables.
# shellcheck disable=SC1091
[ -f "$APP/local_demo.env" ] && . "$APP/local_demo.env"
CEDARDB_BIN=${CEDARDB_BIN:-}
FRONTEND_DIR=${FRONTEND_DIR:?set FRONTEND_DIR (the cloud frontend checkout), e.g. in local_demo.env}
DB_PORT=${DB_PORT:-5730}
WEB_PORT=${WEB_PORT:-8090}
EXPLORER_PORT=${EXPLORER_PORT:-3010}
FRONTEND_PORT=${FRONTEND_PORT:-5198}
WAD=${WAD:-doomu.wad}
MAPS=${MAPS:-E1M1 E1M2 E1M3 E1M4 E1M5 E1M6 E1M7 E1M8 E1M9}
GUESTS=${GUESTS:-4}
EXPLORER_IMAGE=${EXPLORER_IMAGE:-}
EXPLORER_CONTAINER=${EXPLORER_CONTAINER:-doom-explorer-$(basename "$STATE")}
BOTS=${BOTS:-1}
# The mdf proxy the shared demo project needs; the frontend's own .env wins when it has one.
MDF_QUERY_PROXY_TARGET=${MDF_QUERY_PROXY_TARGET:-https://mdf.cedardb.com}
PYTHON=$(command -v python3)
# The frontend's fixed project ids per region key (doomProject.ts); other keys hash.
project_id() {
  case "$1" in
    local) echo 0d00d00d-1993-4e1a-9a11-4d00e1a4e1a0 ;;
    eu) echo 0d00d00d-1993-4e1a-9a11-4d00e1a4e1a1 ;;
    us) echo 0d00d00d-1993-4e1a-9a11-4d00e1a4e1a2 ;;
    *) echo "" ;;
  esac
}
DOOM_PROJECT_ID=$(project_id local)

cd "$APP"
mkdir -p "$STATE/logs"
log() { printf '\033[1m[local_demo]\033[0m %s\n' "$*"; }

pid_alive() { [ -f "$STATE/$1.pid" ] && kill -0 "$(cat "$STATE/$1.pid")" 2>/dev/null; }
stop_one() {
  if pid_alive "$1"; then
    kill "$(cat "$STATE/$1.pid")" 2>/dev/null || true
    for _ in $(seq 1 30); do pid_alive "$1" || break; sleep 0.2; done
    pid_alive "$1" && kill -9 "$(cat "$STATE/$1.pid")" 2>/dev/null || true
  fi
  rm -f "$STATE/$1.pid"
}
# Start a process detached, its pid in $STATE/<name>.pid, output in logs/<name>.log.
start_one() {
  local name=$1; shift
  setsid nohup "$@" >> "$STATE/logs/$name.log" 2>&1 < /dev/null &
  echo $! > "$STATE/$name.pid"
}

wait_for_db() {
  for _ in $(seq 1 120); do
    if $PYTHON -c "import psycopg2,os; psycopg2.connect(os.environ['DB_DSN'])" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  echo "the database did not come up; see $STATE/logs/db.log" >&2; return 1
}
wait_for_http() {
  for _ in $(seq 1 120); do
    if curl -sf -o /dev/null "$1"; then return 0; fi
    sleep 0.5
  done
  echo "no answer from $1" >&2; return 1
}

# The cloud frontend from $FRONTEND_DIR: no sign-in, the mock fleet with the
# shared demo and one Doom project per host, both query proxies through Vite.
# $1: the VITE_DOOM_HOSTS value (key=url@region;...), $2: DOOM_QUERY_PROXY_TARGETS.
start_frontend() {
  local hosts=$1 targets=$2
  [ -d "$FRONTEND_DIR/node_modules" ] || { echo "no node_modules in $FRONTEND_DIR; run npm ci there first" >&2; exit 1; }
  log "starting the cloud frontend on http://localhost:$FRONTEND_PORT/"
  (
    cd "$FRONTEND_DIR"
    # Empty Cognito ids switch auth off entirely. vite's own binary, not npx:
    # npx forks and exits, and the pid file would name a process that is
    # already gone. (No comment may sit inside this continued command: it
    # would end it, and the variables would not reach vite.)
    VITE_COGNITO_USER_POOL_ID= VITE_COGNITO_CLIENT_ID= VITE_USE_MOCKS=true VITE_WAITLIST_GATE=true \
    VITE_MDF_DEMO_ENABLED=true MDF_QUERY_PROXY_TARGET="$MDF_QUERY_PROXY_TARGET" \
    VITE_DOOM_DEMO_ENABLED=true VITE_DOOM_HOSTS="$hosts" DOOM_QUERY_PROXY_TARGETS="$targets" \
    VITE_DOOM_DEMO_ENDS=${DOOM_DEMO_ENDS:-} VITE_DOOM_BLOG_URL=${DOOM_BLOG_URL:-} VITE_DOOM_REPO_URL=${DOOM_REPO_URL:-} \
    VITE_DOOM_INSTANCE_TYPE=${DOOM_INSTANCE_TYPE:-} \
    setsid nohup node node_modules/.bin/vite --port "$FRONTEND_PORT" --strictPort >> "$STATE/logs/frontend.log" 2>&1 < /dev/null &
    echo $! > "$STATE/frontend.pid"
  )
  wait_for_http "http://localhost:$FRONTEND_PORT/"
}

# One console URL per Doom project in a hosts value.
print_project_urls() {
  local entry key id
  IFS=';'
  for entry in $1; do
    key=${entry%%=*}
    [ -n "$key" ] && [ "$key" != "$entry" ] || continue
    id=$(project_id "$key")
    if [ -n "$id" ]; then
      printf '  cloud demo, Doom project %-6s http://localhost:%s/projects/%s/doom\n' "$key:" "$FRONTEND_PORT" "$id"
    else
      printf '  cloud demo, Doom project %-6s http://localhost:%s/projects (hashed id)\n' "$key:" "$FRONTEND_PORT"
    fi
  done
  unset IFS
}

do_stop() {
  log "stopping"
  stop_one frontend; stop_one bots; stop_one web; stop_one referee
  # A dev server or bots from an earlier run whose pid file is gone: by their own command lines.
  pgrep -f "node_modules/.bin/vite --port $FRONTEND_PORT --strictPort" | xargs -r kill 2>/dev/null || true
  pgrep -f "scripts/bots.mjs ws://127.0.0.1:$WEB_PORT/pg" | xargs -r kill 2>/dev/null || true
  docker rm -f "$EXPLORER_CONTAINER" >/dev/null 2>&1 || true
  stop_one db
}

do_status() {
  for name in db referee web bots frontend; do
    if pid_alive "$name"; then echo "  $name: running (pid $(cat "$STATE/$name.pid"))"; else echo "  $name: stopped"; fi
  done
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$EXPLORER_CONTAINER"; then echo "  explorer: running (docker $EXPLORER_CONTAINER)"; else echo "  explorer: stopped"; fi
}

do_check() {
  local password
  password=$(sed -n 's/.*password \(.*\)$/\1/p' "$STATE/spectator.txt" | head -1)
  [ -n "$password" ] || { echo "no spectator login yet; start first" >&2; return 1; }
  $PYTHON scripts/spectator_check.py "dbname=postgres user=doom_spectator password=$password host=127.0.0.1 port=$DB_PORT" \
    > "$STATE/logs/spectator_check.log" 2>&1
  local status=$?
  grep -E "FAIL|LEAK|WARN" "$STATE/logs/spectator_check.log" | sed 's/^/  /' || true
  tail -1 "$STATE/logs/spectator_check.log" | sed 's/^/  /'
  return $status
}

case "${1:-start}" in
  stop) do_stop; exit 0 ;;
  status) do_status; exit 0 ;;
  check) set +e; do_check; exit $? ;;
  sql)
    # One statement as the owner, for poking at the running match.
    # shellcheck disable=SC1091
    set -a; . "$STATE/env"; set +a
    $PYTHON - "${2:?sql statement}" <<'EOF'
import os, sys, psycopg2
conn = psycopg2.connect(os.environ["DB_DSN"]); conn.autocommit = True
cur = conn.cursor(); cur.execute(sys.argv[1])
if cur.description:
    print(" | ".join(c.name for c in cur.description))
    for row in cur.fetchall(): print(" | ".join("" if v is None else str(v) for v in row))
else:
    print(cur.statusmessage)
EOF
    exit $? ;;
  reset) do_stop; rm -rf "$STATE"; log "removed $STATE"; exit 0 ;;
  frontend)
    # Only the console, against remote game hosts. The query proxies go to the
    # same hosts (each one's front door carries /api/query), so they are
    # derived unless DOOM_QUERY_PROXY_TARGETS says otherwise.
    HOSTS=${DOOM_HOSTS:?set DOOM_HOSTS (key=url@region;...), e.g. in local_demo.env}
    TARGETS=${DOOM_QUERY_PROXY_TARGETS:-$(printf '%s' "$HOSTS" | sed 's/@[^;]*//g')}
    stop_one frontend
    pgrep -f "node_modules/.bin/vite --port $FRONTEND_PORT --strictPort" | xargs -r kill 2>/dev/null || true
    start_frontend "$HOSTS" "$TARGETS"
    echo
    print_project_urls "$HOSTS"
    echo "  game hosts: $HOSTS"
    echo "  logs: $STATE/logs/frontend.log    stop: $0 stop"
    exit 0 ;;
  start) ;;
  *) echo "usage: $0 [start|stop|status|check|sql|reset|frontend]" >&2; exit 2 ;;
esac

[ -n "$CEDARDB_BIN" ] && [ -x "$CEDARDB_BIN" ] || { echo "no CedarDB binary at '$CEDARDB_BIN' (set CEDARDB_BIN, e.g. in local_demo.env)" >&2; exit 1; }
[ -n "$EXPLORER_IMAGE" ] || { echo "set EXPLORER_IMAGE (the db-explorer image), e.g. in local_demo.env" >&2; exit 1; }
[ -f "$WAD" ] || { echo "no IWAD at $WAD (set WAD)" >&2; exit 1; }
[ -d "$FRONTEND_DIR/node_modules" ] || { echo "no node_modules in $FRONTEND_DIR; run npm ci there first" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is needed for the spectator's explorer" >&2; exit 1; }

# ---------------------------------------------------------------- owner env
if [ ! -f "$STATE/env" ]; then
  umask 077
  PASSWORD=$($PYTHON -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))')
  cat > "$STATE/env" <<EOF
CEDAR_PASSWORD=$PASSWORD
DB_DSN="dbname=postgres user=postgres password=$PASSWORD host=127.0.0.1 port=$DB_PORT"
EOF
  umask 022
fi
# shellcheck disable=SC1091
set -a; . "$STATE/env"; set +a

# ---------------------------------------------------------------- database
do_stop >/dev/null 2>&1 || true
if [ ! -d "$STATE/db" ]; then
  log "creating the database on 127.0.0.1:$DB_PORT"
  start_one db "$CEDARDB_BIN" -createdb -port="$DB_PORT" -address=127.0.0.1 "$STATE/db"
  wait_for_db
  log "importing $WAD ($MAPS), about a minute"
  # shellcheck disable=SC2086
  $PYTHON wad_loader.py "$WAD" $MAPS --dsn "$DB_DSN" | tail -1
  FRESH=1
else
  log "starting the database on 127.0.0.1:$DB_PORT"
  start_one db "$CEDARDB_BIN" -port="$DB_PORT" -address=127.0.0.1 "$STATE/db"
  wait_for_db
  FRESH=0
fi

log "installing the runtime (functions, api views)"
$PYTHON -c "import psycopg2,os,cedarscript_runtime as r; c=psycopg2.connect(os.environ['DB_DSN']); c.autocommit=True; r.install_cedarscript_runtime(c.cursor())"

# Roles live in the database: provision on a fresh one, refresh grants always.
umask 077
if [ "$FRESH" = 1 ] || [ ! -s "$STATE/players.txt" ]; then
  : > "$STATE/players.txt"
  for player in doom_player1 doom_player2; do
    $PYTHON scripts/add_player.py "$DB_DSN" "$player" | grep browser | sed 's/^ *//' >> "$STATE/players.txt"
  done
  : > "$STATE/guests.txt"
  for i in $(seq 1 "$GUESTS"); do
    $PYTHON scripts/add_player.py "$DB_DSN" "doom_guest$i" | grep browser | sed 's/^ *//' >> "$STATE/guests.txt"
  done
fi
SPECTATOR_PASSWORD=$( [ -s "$STATE/spectator.txt" ] && sed -n 's/.*password \(.*\)$/\1/p' "$STATE/spectator.txt" | head -1 || true)
# shellcheck disable=SC2086
SPECTATOR_OUT=$($PYTHON scripts/add_spectator.py "$DB_DSN" doom_spectator $SPECTATOR_PASSWORD)
printf '%s\n' "$SPECTATOR_OUT" | grep -v "explorer:\|CEDARDB_URL" | sed 's/^/  /'
printf '%s\n' "$SPECTATOR_OUT" | grep "explorer:" | sed 's/^ *//' > "$STATE/spectator.txt"
SPECTATOR_PASSWORD=$(sed -n 's/.*password \(.*\)$/\1/p' "$STATE/spectator.txt" | head -1)
umask 022

# ---------------------------------------------------------------- the match
# Difficulty: the engine's skill_t, 0 to 4 (0 "I'm too young to die", 1 "Hey,
# not too rough", 2 "Hurt me plenty", 3 "Ultra-Violence", 4 "Nightmare!"),
# monsters in or out, and whether the dead ones come back (vanilla -respawn:
# twelve seconds at the least, then a 5-in-256 roll every 32 tics, so about a
# minute on average).
SKILL=${SKILL:-2}
MONSTERS=${MONSTERS:-1}
RESPAWN_MONSTERS=${RESPAWN_MONSTERS:-1}
log "starting the referee (skill $SKILL, monsters $MONSTERS, respawn $RESPAWN_MONSTERS)"
MAP_ID=1 SKILL=$SKILL MONSTERS=$MONSTERS RESPAWN_MONSTERS=$RESPAWN_MONSTERS ALTDEATH=${ALTDEATH:-1} \
  IDLE_SECONDS=5 TIMER_MINUTES=${TIMER_MINUTES:-10} INTERMISSION_SECONDS=10 HOLD_MINUTES=${HOLD_MINUTES:-15} \
  ROTATION=${ROTATION:-E1M1,E1M2,E1M3,E1M4,E1M5,E1M6,E1M7} DB_PARALLEL=4 \
  start_one referee $PYTHON doom_server.py

log "starting the page and tunnel on http://127.0.0.1:$WEB_PORT/"
DOOM_WEB_ADDRESS=127.0.0.1 DOOM_WEB_PORT=$WEB_PORT DOOM_WEB_TARGETS=127.0.0.1:$DB_PORT \
  DOOM_GUESTS_FILE=$STATE/guests.txt DOOM_GUEST_COOLDOWN=8 DOOM_CLIENT_PARALLEL=8 \
  DOOM_MAX_FPS=${DOOM_MAX_FPS:-35} \
  start_one web $PYTHON doom_web.py
wait_for_http "http://127.0.0.1:$WEB_PORT/config.json"

# ---------------------------------------------------------------- bots
if [ "$BOTS" -gt 0 ]; then
  log "starting $BOTS bot player(s) (log in logs/bots.log)"
  DOOM_BOT_FPS=${DOOM_BOT_FPS:-35} start_one bots node scripts/bots.mjs "ws://127.0.0.1:$WEB_PORT/pg" "$BOTS"
fi

# ---------------------------------------------------------------- explorer
log "starting the spectator's explorer on http://127.0.0.1:$EXPLORER_PORT/"
docker run -d --rm --name "$EXPLORER_CONTAINER" --network host \
  -e HOSTNAME=127.0.0.1 -e PORT="$EXPLORER_PORT" \
  -e CEDARDB_URL="postgresql://doom_spectator:$SPECTATOR_PASSWORD@127.0.0.1:$DB_PORT/postgres" \
  -e STATEMENT_TIMEOUT=5000 -e QUERY_TIMEOUT=8000 \
  "$EXPLORER_IMAGE" > /dev/null
wait_for_http "http://127.0.0.1:$EXPLORER_PORT/api/health"

# ---------------------------------------------------------------- frontend
start_frontend "local=http://127.0.0.1:$WEB_PORT@eu-central-1" "local=http://127.0.0.1:$EXPLORER_PORT"

# ---------------------------------------------------------------- the check
log "what the spectator can and cannot do (full output in logs/spectator_check.log)"
set +e
do_check
CHECK=$?
set -e

echo
do_status
echo
echo "  cloud demo, Doom project:  http://localhost:$FRONTEND_PORT/projects/$DOOM_PROJECT_ID/doom"
echo "  the game on its own:       http://127.0.0.1:$WEB_PORT/"
echo "  guest seats: $GUESTS; player logins in $STATE/players.txt"
echo "  logs: $STATE/logs/    stop: $0 stop"
exit $CHECK
