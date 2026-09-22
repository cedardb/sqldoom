# Deathmatch server

The database is the game server. Every rule runs inside it; the only trusted
process outside it is the referee, which keeps 35 Hz time. Players connect as
their own database roles with **no table grants** and reach the game through
`api_*` functions (`SECURITY DEFINER`, `sql/runtime/functions/42_api.sql`) and
`api_*` views (generated from the single-player client's SQL by
`cedarscript_runtime.install_api_views`, run with their owner's rights). Both
resolve the caller from `session_user`, so a client cannot name another
player's slot: there is no parameter for it.

Any number of players can be provisioned. A match has four slots, one per
player start as in vanilla Doom; `api_join` hands the lowest free one to whoever asks, and a slot whose holder has gone
quiet (closed tab, dropped connection) is given back by the referee after
`IDLE_SECONDS` (default 5). Everyone else waits in the lobby.

## Roles

| role | may | may not |
|---|---|---|
| database owner (`postgres`) | everything: import, referee, single player | |
| a player (`scripts/add_player.py`) | `api_join`, `api_slot`, `api_input`, `api_camera`, `api_weapon_slot/cycle`, `api_automap`; `SELECT` on `api_snapshot`, `api_player_state`, `api_scoreboard`, `api_sound_*`, `api_stage_music`, `api_map_lines`, `api_map_geometry`, `api_stages`, `api_palettes`, `sound_assets`, the per-slot frame views (which return a frame only to the slot's holder); `USAGE` on sequences | read any table, write anything, advance the tic, cheat, reset or open a level, take another player's slot or frame, name its own camera, or ask the automap to reveal the map |

Roles live in the database, and `CREATE OR REPLACE VIEW` drops a view's
grants, so provisioned roles are recorded in `api_roles` and every runtime
install re-grants them. Run `add_player.py` again after a fresh import.

## One referee per map

Two referees on one map would run the world at double speed (bobbing, movement
and fire rate all tied to tics), so the referee keeps a heartbeat row in
`mp_referee` and refuses to start while another one is fresh. Ctrl-C and
SIGTERM release it; after a crash the next start waits out 3 seconds. At start
the referee also runs the join path once, so the first real join no longer
freezes the world while it compiles.

## Running

```
# owner: import, then players (any number)
python3 wad_loader.py doomu.wad E1M1 ... E1M9 --dsn "$OWNER_DSN"
python3 scripts/add_player.py "$OWNER_DSN" alice            # prints a password once
python3 scripts/add_player.py "$OWNER_DSN" bob 'chosen-password'

# owner: the referee (opens the match, compiles the per-slot frame views, keeps time)
# SKILL is the engine's skill_t, 0 to 4: 2 is "Hurt me plenty", 3 Ultra-Violence
DB_DSN="$OWNER_DSN" MAP_ID=1 SKILL=2 python3 doom_server.py

# owner: the web front door (static page + WebSocket tunnel to CedarDB)
DOOM_WEB_PORT=8080 DOOM_WEB_TARGETS="127.0.0.1:5720" python3 doom_web.py
```

Players then open `http://<host>:8080/`, pick the server, and sign in with
their role's name and password. The native client still works too:

```
DB_DSN="dbname=postgres user=alice password=... host=<server> port=<port>" DOOM_JOIN=1 python3 doom_client.py
```

Bind CedarDB beyond loopback with `-address=0.0.0.0` and put TLS in front per
the CedarDB documentation (`cert.pem`/`key.pem` next to the binary). For the
web page, terminate TLS in a reverse proxy in front of `doom_web.py`; the
tunnel then runs over `wss://`.

## Capacity and parallelism (measured on a 96-core EPYC 9654P)

`scripts/render_capacity.py OWNER_DSN` runs N renderers next to a 35 Hz ticker
(`--no-tic` for renderers only) and prints frames per second per renderer.

- A frame is about 28 ms of single-threaded CPU; parallelism does not shorten
  it. Sessions cap themselves with `max_parallel_workers` (4 to 8 is best, the
  default of every core costs a third for a solo client), which `env` sets for
  browsers, native clients (`DOOM_CLIENT_PARALLEL`) and the referee
  (`DB_PARALLEL`).
- The renderer joins textures once per visible seg part (`wall_parts_tex`) and
  carries the pixels down as columns. Joining `walltex_meta` per column and per
  fragment instead was 58,000 B-tree point lookups per frame into the same few
  leaf pages; each takes a shared latch, and with many sessions those latch
  words bounce between cores. That alone capped the whole server near 220
  frames per second and made 16 renderers burn 57 cores for 255 ms of CPU per
  frame. Now:

| renderers | fps each | total |
|---|---|---|
| 1 | 35.5 | 36 |
| 2 | 35 | 70 |
| 4 | 34 | 137 |
| 8 | 32 | 254 |
| 16 | 24 | 389 |

- The tic is never the limit: 1 to 2 ms at every setting.
- Over Tailscale the page keeps two frame requests in flight so the round trip
  overlaps the render; a browser then sees about 28 fps per player on this box
  (the per-slot view path costs a few ms more than the owner path the capacity
  script measures), and a third request in flight only added latency.

Four players render at 34 fps each on this box, so the four slots fit with
room to spare. Two CedarDB findings came out of this: idle scheduler workers used to
wake on every pipeline start and burn 1.5 percent each (fixed upstream on
2026-09-07), and a shared latch per point lookup is what limits many sessions
reading the same small pages.

## Four players

`doom_run_tic_core` takes p1..p4 (NULL for an empty slot); every per-player
stage group is a function (`doom_tic_use`, `doom_tic_move`, `doom_tic_secrets`,
`doom_tic_weapon`, `doom_tic_dm_player`) called once per occupied slot, and
single player passes three NULLs, so the two paths cannot drift. `doom_mp_start`
opens a slot per player start (types 1 to 4), all free and dead until claimed.
The other players are drawn as the PLAY sprite in Doom's per-player colours:
slot 1 green, 2 indigo, 3 brown, 4 red (the 0x70..0x7F range remapped as in
R_InitTranslationTables).

## A match that runs for days

The referee runs the match the way a 1990s server did, all of it as rows in
`mp_match` and `mp_rotation` and read by the tic:

- **-altdeath** (deathmatch 2.0): a taken item returns 30 seconds later where
  it stood, with the IFOG fog and DSITMBK, one per tic, oldest first
  (`doom_cs_item_respawn`, P_RespawnSpecials). Dropped weapons never return.
- **-timer** `TIMER_MINUTES` (10): the level ends when the clock runs out, or
  when any player uses or crosses an exit line, exactly as vanilla's
  G_ExitLevel (`doom_mp_level_done`, which the tic returns). The frag table
  shows for `INTERMISSION_SECONDS`, then the next map of `ROTATION`
  (E1M1 to E1M7, wrapping; vanilla would end the episode after map 8).
- **monsters** stay in unless `MONSTERS=0`, and come back as with vanilla
  -respawn (`RESPAWN_MONSTERS`): twelve seconds at the least, then a 5-in-256
  roll every 32 tics, about a minute on average. Every tic offers the world
  stages a different live player, so monsters notice everyone; a monster
  keeps the target it picked until that player dies or leaves. A target can
  also be the thing that hit it, a barrel included, and a dead one is dropped
  the same way. Until 2026-09-13 a monster whose target had died fell out of
  the state machine altogether: killed at that moment it stayed in its attack
  pose, dead but never dying and unshootable, and an imp and the barrel it lit
  froze each other for the rest of the map.
- **The automap** draws only what the player has walked, unless they are
  holding the computer map -- `api_automap` reads that off `power_map` rather
  than taking it as an argument, since a client that could ask for the whole
  map would simply always ask. IDDT is not reachable in a match at all: it is
  the setting that draws every thing, which is a radar of where everyone is.
- **Slots follow players.** `doom_mp_rotate` opens the next map and hands
  every held slot to the same role there; the first tic respawns them.
  Frags start at zero per map, as vanilla's frag table does.
- **Nobody keeps a seat while others wait.** A seat held longer than
  `HOLD_MINUTES` (15; 0 for no limit) goes back to the lobby, but only while
  somebody is actually waiting there: an empty room is nobody's problem. The
  claim time follows the player across maps (`mp_players.claimed_at`, via
  `mp_holders`), the limit is in `mp_match.hold_seconds`, and `api_match`
  shows both (`hold_seconds`, `my_seat_seconds`) so the page can say why it
  lost the seat rather than guessing at idleness. Schema change of
  2026-09-13: an existing database needs `REBUILD=1` (or `local_demo.sh
  reset`).

Between maps the player API is quiet: joins, inputs and poses are no-ops
while `mp_match.state` is `intermission`, nobody is reaped, and the switch
runs without a single serialization conflict. The frame views exist per slot
and map (`api_frame_idx_slot<n>_m<map>`), created once when the referee
starts: replacing a view would make CedarDB recompile every prepared
statement on the server, the tic included, which is several seconds of
frozen world. Clients read `api_match` (state, map, time left, next map) and
re-prepare their frame statement when the map changes. The native client
plays a single map; the browser client follows the rotation.

`scripts/mp_rotation_check.py OWNER_DSN P1_DSN P2_DSN` runs the whole cycle
with a 40-second timer: item respawn, the timer, the intermission, the
switch, the carried-over slots, and two bots rendering on both maps.

## Guests: playing without an account

A public page cannot hand out passwords, so the relay does it. Configure a
pool of roles exactly like players (the same API grants, nothing else), write
their logins to a file readable only by the service account, and pass its path
to `doom_web.py` as `DOOM_GUESTS_FILE`. A page that opens the tunnel with
`?guest=1` is leased one free seat for the life of its WebSocket: the relay
sends `{"user","password"}` as the first text frame, the page's wire client
then runs the normal SCRAM startup with it. When the connection closes the
seat rests `DOOM_GUEST_COOLDOWN` seconds (longer than `IDLE_SECONDS`) so the
referee has reaped its slot before the next visitor gets the same role. With
no seats free the relay answers `{"error": ...}` and the page says so. The
relay still never parses a Postgres byte; it only hands out a login it was
given, and that login can reach nothing but the player API through the tunnel.

The page defaults to PLAY as a guest with a nickname (`api_set_name`, twelve
characters, what the frag board and the "X FRAGGED YOU" messages show); the
account form is behind a link and is the only form when no seats are
configured. `node scripts/web_browser_check.mjs URL guest "Nick"` exercises
the guest path.

## What the referee logs

Every second: slot claims and frees with the role and name (`slot 2 claimed
by doom_guest3 "LUKAS"`, `slot 2 freed (doom_guest3, 4 frags, idle)`), the
level's end and the switch. Every five seconds two lines: the map, state and
time left; tic median, p90, max, count and dropped tics; and from the
`mp_stats` view monsters alive/total/awake, projectiles, effects, movers,
items out and queued for respawn, inputs waiting, sound rows, database
sessions; then the board. All of it is one small aggregate query per five
seconds, nothing per tic.

## Bot players

A public match should have somebody in it at three in the morning, a visitor
should have somebody to fight, and a burn test should have the load of real
players. `scripts/bots.mjs` is all three: N guests through the relay with the
page's own wire client, frames pulled at the page's rate (`DOOM_BOT_FPS`, 35;
0 pulls as fast as the database answers, the burn setting), inputs at 35 Hz.
A bot reads only what any player may read: its own `api_player_state`, the
live overview `api_things_live` (granted to the player roles for this; the
console's map shows the same positions to everyone), and the automap's lines
for line of sight, where one-sided and special lines count as opaque so a
closed door hides what is behind it. Seven times a second it picks a target,
the nearest opponent in sight with people before monsters, and a goal, the
nearest opponent anywhere. With a target it turns at a fast mouse's speed with
a little aim wobble, fires after a short reaction delay in bursts, circles at
shotgun range, backs off when crowded and switches to the best weapon it has
ammo for. Without one it walks toward the goal; Doom slides a player along
walls, so "stuck" is making no headway rather than standing still, and then
it presses use, turns well away and tries again. `DOOM_BOT_SKILL` (0 to 1,
0.6) sets reaction, aim and turn speed. The original game had no bots at all;
these are about as good as the Cajun bots the source release brought.

Etiquette: a bot takes a seat only while a slot is free and nobody is in the
lobby, and asks once (a refused `api_join` leaves a lobby row behind for five
seconds, which the referee would count as somebody waiting). Once seated it
watches `api_match.waiting` and leaves within a second of anyone appearing
there, then stays away for 15 to 30 seconds so the person can sit down. It
also gives up its seat about every `rejoin` seconds (900) so seats churn.
`scripts/local_demo.sh` starts `BOTS` (1) of them locally, and their minute
lines in `logs/bots.log` carry fps, frags, deaths and the share of time spent
hunting.

Egress is the running cost of a public host: a frame is 64 KB before the
tunnel's XOR-delta and deflate, about 15 KB after (`scripts/egress_probe.mjs`
records a guest's frames and compares codings; level 9 and a previous-frame
dictionary gain nothing over what the relay does). The one real knob is the
frame rate: a wide server answers past 60 fps, the page now asks for at most
`DOOM_MAX_FPS` (35, Doom's own; `config.json` carries it, 0 lifts the cap),
which is 1.9 GB an hour per player, and a tab that goes to the background
leaves the game rather than streaming frames nobody sees.

Embedded (`?embed=1` inside an iframe) the page is nothing but the 16:10
screen, so the host page can draw the name field, the button and the two
text lines in its own style and the whole thing reads as one surface. The
two sides talk over `postMessage`: the host sends `{source:'sqldoom-host',
action:'play', nick}` or `action:'stop'`; the page answers with
`{source:'sqldoom', kind:'ready'|'state'|'status'|'stats', ...}`, where
`state` is `connecting`, `lobby`, `playing` or `stopped` and `status` and
`stats` carry the lines it would have printed under its screen. Nothing in
those messages is game state a player could act on; the host has the
spectator's SQL for that. `?nick=` prefills the name, and `config.json`
answers any origin, which is how the demo's tab learns whether the match is
on and how many seats are free. When the box is switched off that probe
fails and the tab turns into its closing note by itself.

## What the first burn test found

Seven hours on the 96-core EPYC box with four guest bots and a 3-minute rotation
(`scripts/bots.mjs`, then blind wanderers called `burn_bots.mjs`,
`scripts/burn_sampler.py`, `scripts/burn_report.py`):

- **A tic that fails keeps failing, and grows.** The item respawn queue was
  filled with a join to `pickup_defs`, which has two rows per weapon, and
  CedarDB rejects the same key twice inside one `INSERT ... ON CONFLICT DO
  NOTHING` (Postgres does not; `CEDARDB_REPROS.md`). The first shotgun taken on
  E1M3 made every tic fail. Each failed tic rolled back the delete of the
  inputs it had consumed, so `mp_inputs` grew to 1.6 million rows and the tic
  to 20 seconds. Fixed twice: the insert deduplicates in its SELECT, and the
  referee drops a failed tic's inputs itself. Two rarer cousins went the same
  way: two special events on one tag in one tic (now one event per tag and
  mechanic), two chase steps for one monster (now grouped).
- **`ON CONFLICT DO UPDATE` applies its update whatever the `WHERE` says**, so
  the manual-door toggle's condition moved into the `SET` list.
- **Everything else was flat.** `world_effects`, `monster_deaths`,
  `item_respawns`, `picked_up_items`, the line tables: bounded by the map.
  `sound_events` grew about 800 rows a minute and was only cleared at the map
  switch; the referee now trims positional cues older than two seconds every
  second, keeping the one-shot latch keys (`mon-sight:`, `mon-death:`,
  `plr-death:`) that must not fire twice.
- **Replanning.** CedarDB re-plans every parameterised prepared statement once
  per `debug.optimizer.replantimems` (60 s by default), server-wide, and
  re-planning a frame query stalls that browser for about 1.25 s. Only the
  native client used to raise it; the referee now sets it to a day at startup
  (`REPLAN_MS`). The good plan comes from the first execution, not from the
  interval (measurements in `doom_config.py`).
- **Not a burn finding, but from the same night:** `SET compilationmode` is
  also server-wide and persistent; left at `C` after an experiment it made
  every statement compile through gcc.

### The second burn (2026-09-08, 05:25 UTC onwards, 4 bots, 3-minute maps)

Ten hours and a hundred maps in: tic median 11 ms and p90 13 ms in the tenth
hour against 14 and 16 in the first, every table bounded across the switches,
relay and referee memory flat. What it found, and what changed for it:

- The referee died twice, restarted by systemd each time: once in the rotate
  (the `mp_holders` duplicate key, already an upsert here), once when a reap
  lost a race with a player's own api call (a serialization failure).
  Heartbeat and reap now run under a try; a failure is logged once and retried
  a second later.
- Guest seats ran out with two bots playing. Seven of the eight seats were held
  by tunnels the bot process itself had left open: a session that threw kept
  its WebSocket, and the relay rightly kept the lease. The bots close the
  socket in a `finally` now. The eighth was a browser that vanished without a
  close frame; nothing ever closed that tunnel. The relay now pings a tunnel
  that has been silent for `DOOM_WS_IDLE` seconds (45) and closes it after
  another such interval, which frees the seat.
- 159 dropped tics in ten hours with `null value violates not-null constraint`
  and no table named, six with `more than one row returned by a subquery`, and
  a scatter of duplicate keys on `monster_steps` and
  `level_secret_discoveries`, all at a steady one per few minutes and never on
  the local machine. They look like one thing: a row version briefly visible
  twice, or not at all, under the concurrent api traffic. See
  CEDARDB_REPROS.md; the referee drops the tic and carries on.
- CedarDB's RSS grew from 25.0 to 28.2 GB over the ten hours, about 330 MB an
  hour, straight, with the tables bounded. Not yet explained.
- `mp_inputs` once climbed to 20,000 rows over three minutes on E1M5 with the
  tic running and nothing dropped, and emptied at the rotation. Inputs from a
  role that no longer held a slot, most likely; the api of this build only
  inserts for a role that has one.

### What the burn's CedarDB findings turned out to be (2026-09-09)

The steady drops, the two stuck rotations and the memory growth traced back to one knob: a session
that leaves `max_parallel_workers` at the server default (one per core, 192 on the 96-core EPYC box) runs its
frame queries over ~200 worker threads, and while such queries run, *other* sessions' table scans
over small row-page tables occasionally return nothing at all (a `SELECT count(*)` on a one-row
table returns 0, an UPDATE without WHERE updates nothing, no error; index lookups are unaffected). The browser sets the relay's `parallel` (8) on connect;
the burn bots did not, and were the only clients at the default. At 8 workers the probe finds
nothing; at 32, a quarter of the default rate; at 192, about five bad statements a second across
the server. CEDARDB_REPROS.md has the table and the reproduction; `scripts/cedardb_snapshot_probe.py`
is the detector. The bots now set 8 like the browser. Memory: the instance grew only while such
clients played, was flat for nine idle hours, and gave 2 GB back after a burst of probes, so it is
elastic working memory of the wide queries rather than a leak; a fresh instance under version churn
plateaued at 1.7 GB.

## The browser client (`web/`)

A browser cannot open a Postgres connection, so `doom_web.py` relays bytes:
WebSocket in, TCP to CedarDB out. It is a dumb pipe with an allowlist of
endpoints (`DOOM_WEB_TARGETS`); it never parses SQL and never sees a password
in the clear, because the page speaks the Postgres wire protocol itself
(`web/pgwire.js`: startup, SCRAM-SHA-256, Parse once, then Bind/Execute
pipelined under one Sync with binary result columns). `web/app.js` is the
native client's join mode with pygame swapped for a canvas and WebAudio: one
input row per 35 Hz tic, camera plus frame as fast as the database answers,
sounds from `api_sound_events`. Even the camera interpolation is the
database's (`api_camera`), so the page holds no game logic at all. Tab is the
automap (`api_automap`, the same composite the native client draws, with F for
follow, G for the grid, +/- or the wheel to zoom and the arrows to pan when not
following); Shift+Tab holds the frag board, which also comes up while dead.

Bandwidth: the page reads `api_frame_idx_slot<n>_m<map>`, the renderer emitting one
COLORMAP-mapped palette index per pixel behind a palette-number byte (64001
bytes instead of 192000 of RGB) and applies PLAYPAL (`api_palettes`) in the
blit. The tunnel negotiates WebSocket permessage-deflate, which takes DOOM's
flat runs down another 2.3 to 3x, so a 35 fps stream is roughly 700 KB/s on
the wire. With the `pg-delta` subprotocol the relay also XORs every large
binary result column against the previous one of the same size on that
connection before compressing, and the page undoes it after decoding the row;
this is the one place the relay reads the Postgres stream (message
boundaries and one column length, never content). Measured with the smoke
script: a player who stands still goes from x2.4 to x40 (0.6 MB in 10 s
instead of 9), a player running and turning from x2.6 to x2.4, because the
XOR of two shifted images is noisier than either. Egress is bounded by the
four slots either way: about 0.2 to 0.65 MB/s per player, so a permanently
full server is 66 to 220 GB a day.

The lobby is a queue. A caller without a slot is a waiter from its first
`api_join` (`mp_waiting`, kept alive while it keeps asking, dropped after
five quiet seconds), a free slot goes to the earliest waiter only, and
`api_match` tells every caller how many wait and how many arrived before it;
the page shows "WAITING FOR A SLOT, 2 AHEAD OF YOU". A slot a player leaves
right after joining stays held for the rest of the 15 s join grace, then the
reaper's `IDLE_SECONDS`.

## The whole of Doom 1

All 36 maps of The Ultimate Doom load and play end to end in SQL: every item
(the skull keys, invulnerability), every finale (the text screens of all four
episodes, the bunny scroller, the ENDPIC), the full line special catalogue
(about 140 specials: doors, floors, lifts, ceilings, crushers, stairs, lights,
teleports, donuts, the stop lines) and every monster in the IWAD. The four
that only appear from episode 2 on came last: the cacodemon and lost soul
float (a step in the floor does not stop them, they drift toward their
target's height, the soul's charge is real momentum carried by the thing
physics), the cyberdemon fires three rockets per attack, the spider
mastermind's chaingun is three hitscan pellets per frame. The tic planner
only runs the projectile stage when something that throws one has fired, so
the new throwers are in that list too (`10_cs_plan.sql`).

Doom's `#define`s live in `doom_constants` (name, value, and where the value
comes from: `FRICTION 0.90625 = 0xe800/65536, p_mobj.c`). A function reads
the ones it needs into CedarScript variables at entry (`let friction =
doom_const('FRICTION')`), one lookup per call and none per row, so the rule
reads `s.mx * friction` where p_mobj.c reads `FixedMul(mo->momx, FRICTION)`.
Player movement, thing physics, the monsters, the projectiles and the respawn
timers read theirs this way; pure geometry (320 by 200, the status bar's row
168) stays literal, as it does in Doom.
The one exception is FRICTION in the thing physics, which is a typed literal
(`let friction = 0.90625::real`, the way p_mobj.c has `#define FRICTION`):
a function result is a nullable float8 as far as the compiler knows, and
that costs the UPDATE's row body a null test, a NOT NULL check and a range
check per column, so the compiled code is cleaner with the literal.

Every state, kind and mode the code compares against is an enum type
(`weapon_state`, `actor_state`, `screen_kind`, `mover_kind`, ... 24 of them
at the top of `sql/schema.sql`, 33 columns). A misspelt literal (`'misile'`)
is now an error at load time instead of a condition that never matches.
CedarDB coerces a string literal to the enum on its own, but not a text
variable, parameter or column, so a CedarScript `let` that holds a state is
written `'up'::weapon_state`, and a CASE that mixes literal branches with an
enum column has each literal cast. `CREATE TYPE` has no `IF NOT EXISTS`;
`wad_loader.apply_schema` skips the types that already exist so the schema
stays re-runnable.

No query names a monster by its editor number. `thing_combat_defs` carries
what the code asks about a thing -- `floats`, `skull_fly`, `missile_type`
with `missile_speed` and `missile_dice`, `hitscan_pellets`, `melee_mult` and
`melee_sides`, `height` (what a crusher has to reach), `fast_on_nightmare`,
`attack_sound`, `explodes` -- plus a `name` for the reader, and the planner,
the projectile spawn, the monster script, the thing physics, the crushers,
the sound cues and the renderer join it. A new monster is a row there and a
state table in `thing_ai_frames`, and the melee rolls all draw from one
P_Random stream now (they used to differ per type). A stage reset also puts
`render_things.sector_id` back to `spawn_sector_id`: the monster mover keeps
the sector current, and a floater's start height is read from it, which is
what made two playthroughs of E2M3 differ before.

## Verified

- `scripts/mp_acl_check.py OWNER_DSN P1_DSN P2_DSN`, with a referee open, tries
  every statement a player must and must not be able to run.
- `scripts/mp_api_match.py OWNER_DSN MAP SECONDS P1_DSN P2_DSN` starts a
  referee and plays a match through the API with two bot clients as roles.
- `scripts/mp_frag_check.py OWNER_DSN` has each player kill the other with the
  pistol and checks the frag accounting both ways.
- `node scripts/web_smoke.mjs ws://host:8080/pg user password [seconds]` drives
  the page's own wire client through the tunnel: sign in, claim, frames.
- `node scripts/web_browser_check.mjs http://host:8080/ user password [seconds] [png]`
  runs the page in headless Chrome: signs in, moves, turns, fires, and reports
  the page's stats line, console errors and a screenshot.
- `scripts/all_maps_smoke.py OWNER_DSN --tics 300` plays a scripted 300 tics
  on every loaded map and renders a frame of each.
- `scripts/determinism_check.py --dsn OWNER_DSN` replays every map twice from the
  same seed and compares the world hashes.
- `scripts/specials_check.py OWNER_DSN` fires every line special on a real
  line and checks the tagged sectors move where vanilla's rules say.
- `scripts/monsters_check.py OWNER_DSN` puts the player in front of one
  monster of each type and checks it wakes, chases, fires the right thing and
  hurts.
