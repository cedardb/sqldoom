#!/bin/bash
# Run a command against the doom database, starting the server first if it is
# down. CedarDB ignores SIGTERM/SIGINT, so a stop is always kill -KILL, and the
# server must be started with stdin closed or it dies with the calling shell.
DB=${DOOM_DB:-/home/lukas/cedar/doomdb/doom.new}
PORT=${DOOM_PORT:-5720}
LOG=${DOOM_LOG:-/home/lukas/cedar/doomdb/server.new.log}
BIN=${CEDARDB:-/home/lukas/cedar/cedardb/cmake-build-release/cedardb}
export PGPASSWORD=${PGPASSWORD:-y44LkYQQ0LczjzslxEzHS36Bh}
up() { psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc "select 1" >/dev/null 2>&1; }
if ! up; then
  pgrep -f "cedardb -port=$PORT" | xargs -r kill -KILL
  sleep 1
  ( cd "$(dirname "$BIN")" && setsid nohup "./$(basename "$BIN")" -port="$PORT" \
      -address=127.0.0.1 "$DB" >>"$LOG" 2>&1 < /dev/null & )
  for _ in $(seq 1 60); do up && break; sleep 1; done
fi
up || { echo "server would not start; see $LOG"; exit 1; }
"$@"
