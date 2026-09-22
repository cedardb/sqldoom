# SQLDoom

SQLDoom ports the original 1993 Doom's game logic and renderer to SQL and runs it inside CedarDB.
The game loop runs at the original 35 FPS, while the renderer produces the complete 320x200 frame buffer at up to 60 Hz on a run of the mill Laptop.
It talks to the database over the Postgres wire protocol and currently requires CedarDB as it uses `cedarscript` for some functions, but could be easily ported to `plpgsql`.
Python only handles timing, reads the keyboard, and displays the bitmap it gets back. Multiplayer also works.


- [Full write up -> ](https://cedardb.com/blog/sqldoom)
- [Live demo (EU) ->](https://demo.cedardb.cloud/projects/38c0ee59-327d-495e-ad40-735521bba941)
- [Live demo (US) ->](https://demo.cedardb.cloud/projects/f23db33c-f37e-4a28-b73a-1c8151661179)


SQLDoom is a successor to [DOOMQL](https://cedardb.com/blog/doomql) [[Github]](https://github.com/cedardb/doomql)
which was just a raycast ASCII approximation of Doom.
This version is a more-or-less complete port of Doom, including WAD loading, BSP tree traversal, and textures.

One of these is the 1993 binary. The other is a SQL query. Can you figure out which is which?

![](assets/vanilla_vs_sqldoom.png)

Gibbing 3 soldiers with a rocket launcher

![](assets/gib.webp)

## Constraints

1. It should look like the real Doom.
2. But more importantly, it also should *feel* like the real Doom. The original game is just raw *fun*.
3. The rendering must be purely SQL-based. The only acceptable SQL output is a table or a bitmap encoding exact RGB values for every pixel.
4. The game loop must also be purely SQL-based. It's okay to use user-defined-functions inside the DB, though.
5. The Python client only handles input, drives the game tics and renders the output bitmap.

## Architecture

Python is deliberately boring (Rule 5). It uses `pygame` to drive input and output and
triggers a game tic 35 times a second.
Game logic, game state, and renderer live inside the database.

```
                    doom_client.py
                    doom_server.py (deathmatch only)
                    doom_web.py (deathmatch only)
                 input / timing / display
                    |              ^
                    |              |
          run game tic        request frame
                    |              |
                    v              |
          +----------------+  +----------------+
          |                |  |                |
          | SQL game logic |  |  SQL renderer  |
          | sql/runtime/*  |  |sql/renderer.sql|
          +-------+--------+  +--------+-------+
                  |                    ^
                  |                    |
                  v                    |
             +-----------------------------+
             |                             |
             |       game state tables     |
             |       sql/schema.sql        |
             +-----------------------------+
```

The two paths are intentionally separate: The game logic is triggered on a fixed loop while the client
can asynchronously request a new frame whenever it wants.

## Importing a WAD

Doom's [.wad file format](https://doom.fandom.com/wiki/WAD) is already relational.
The importer (`wad_loader.py`) is about 1300 lines of Python and imports Doom 1 in about 18 seconds.
It writes the tables `sql/schema.sql` defines from the original WAD, populates static data that lived in
Doom's original executable (`sql/loader/*.sql`) and materializes some intermediate results (`sql/loader/functions/*.sql`). 

## The Game Loop

The original Doom ran on a fixed 35 Hz clock, so a tic has a budget of `1000 ms / 35 Hz = 28.6 ms`.
It also drew exactly one frame per tic, so it was capped at 35 FPS as well.

SQLDoom keeps the game logic at 35 Hz (so all the original constants still work), but decouples the drawing.
The client can query (get it?) for a frame whenever it likes and we interpolate the camera position between tics.
So there are two budgets we have to take care of:
- Running a tic every 28.6 ms (or it will feel just completely wrong)
- Rendering at least 35 frames a second (less is kind of okay, but won't feel smooth)

### The tic sequence

Game tics are inherently procedural. We have a sequence of things we have to do each time we run the tic.
CedarDB has a scripting language called `cedarscript`, it closely resembles `plpgsql` and allows us to plan beforehand what to do each tic.

Here is a small section of the tic function:
```sql
doom_cs_clock(map, p);
let mut plan = doom_cs_plan(map, p);              -- returns a bitmask with which functions need triggering this turn

let use_queued = doom_tic_use(map, p, plan);
if (plan & 2) <> 0 OR use_queued { active = doom_cs_activate_specials(map); }
if (plan & 4) <> 0 OR active <> 0 { doom_cs_doors(map, p); }
...
```
The python driver from above calls `SELECT doom_run_game_tic(...)` every `1/35` second.
The functions called live in `sql/runtime/functions`. Every function that is a stage of 
the tic has its name prefixed by `doom_cs_*`.

A more typical tic with 6 monsters awake takes 2.15 milliseconds on average, or about 8% of the budget.
Worst case was E4M1 with 10.45 ms ( 37%) where 46 monsters are awake at the same time.

The whole tic logic takes about 5900 lines of SQL, compared to Doom's original 9000.

## Rendering

Every frame is just a giant view that reads the level geometry and game state plus
the player position as input and returns a complete framebuffer.
Here's a sketch of the whole rendering pipeline (`sql/renderer.sql`):

```sql
WITH RECURSIVE
  render_context AS (SELECT $1 AS map_id, $2 AS player_thing_id, $3 AS difficulty),
  pos            AS (SELECT $4 AS x, $5 AS y, $6 AS z, $7 AS angle),
  visible_children AS ( ... ),    -- walk the BSP, culling invisible segments on the way
  clipped, projected, on_screen,  -- project segments to screen space
  wall_parts, columns, fragments, -- one row per wall pixel
  panel_clips, plane_spans, ...,  -- ceilingclip/floorclip as window functions, visplanes
  thing_pixels, sprite_fragments, -- sprites
  fragment_union, resolved,       -- every candidate pixel, resolve for the nearest
  view_colored, ui_colored,       -- COLORMAP, status bar
  framebuffer AS ( ... )          -- 64,000 rows of (x, y, rgb)
SELECT string_agg(rgb, ''::bytea ORDER BY y, x) AS frame_rgb
FROM framebuffer;                  -- 192,000 bytes, one row
```

The implementation is ~1300 lines of SQL (excluding comments) spread across 89 CTEs, so pretty complicated for a SQL query!

But despite looking like complete insanity, this pipeline is actually pretty close to what Doom does.
SQL even has one advantage:
The [`linux_doom` source](https://github.com/id-Software/Doom/tree/master/linuxdoom-1.10) uses about 3300 lines (excluding comments)
for its rendering engine. *About 2.5x more lines than SQLDoom*.

### How a frame is built

* front-to-back order: every root to subsector path of the BSP tree is precomputed at import (`wad_sql.py`) and then packed into a bigint, allowing us to replace the recursive descent with an `order by`.
* floors and ceilings: panels per screen column are ordered by depth with window functions.
* resolve for nearest pixel: For each pixel, we get the closest candidate pixel with a `min()` aggregate.


```sql
((LEAST(depth, 131071.0) * 4096)::bigint << 34)   -- depth first, clamped to a 17.12 fixed-point number
| ((2 - surface_priority) << 32)                  -- wall > sprite > plane
| (LEAST(source_priority, 3) << 30)
| ((stable_id + 32768) << 14)                     -- stable tiebreak
| (light_index << 8) | palette_index              -- the payload
AS winner_key
...
SELECT pix, MIN(winner_key) FROM ranked_fragments GROUP BY pix
```

On my Laptop (Ryzen 7 PRO 7840U) I typically get about 60 FPS, but it drops down to 35 FPS on very busy scenes.

The most expensive parts of the pipeline are (unsurprisingly):
- rendering visplanes (where we have to emulate an iterative algorithm),
- depth resolve (which the original Doom successfully avoids in the first place),
- and everything that has to happen per pixel (e.g., colormap lookup, packing the framebuffer)

## Modding

The player's shotgun is just a row (loaded from `sql/loader/game_data.sql`):
```console
doom=# SELECT name, ammo_type, ammo_per_shot, pellet_count,
doom-#        dmg_dice_count, dmg_dice_mult, max_range
doom-#   FROM weapon_defs WHERE name = 'shotgun';
  name   | ammo_type | ammo_per_shot | pellet_count | dmg_dice_count | dmg_dice_mult | max_range
---------+-----------+---------------+--------------+----------------+---------------+-----------
 shotgun | shells    |             1 |            7 |              3 |             5 |      2048
(1 row)
```
Seven pellets, each doing `3d5` damage. 

Even the animation is data! Here's the entire state machine of the shotgun:

```console
doom=# SELECT state, seq_index AS seq, frame, tics,
doom-#        is_attack_frame AS shoots, refire_check AS refire
doom-#   FROM weapon_frames WHERE weapon_id = 3 ORDER BY state, seq_index;
 state | seq | frame | tics | shoots | refire
-------+-----+-------+------+--------+--------
 ready |   0 | A     |    1 | f      | f
 fire  |   0 | A     |    3 | f      | f
 fire  |   1 | A     |    7 | t      | f
...
(12 rows)
```

Properties of things just being stored in a table also makes it *really* easy to mod *everything*.

## Multiplayer

A database gives us a lot of stuff needed for a multiplayer game for free:
- Authentication
- Concurrency control
- Access control
- Consistent snapshots of the game state
- Binary wire protocol


A separate Python `referee` script drives the shared 35 Hz clock and rotates the map. The player's clients online supply the input.

The part I like the most, though, is atomicity: Whenever we run a game tic, we can just say `begin transaction`, and `commit` in the end.
Every player (Doom deathmatch supports up to 4) still gets a consistent view, either the way the world looked like
before the tic transaction was started, or after it fully committed. No partially applied updates, physics bugs, or disagreements over
whether the rocket actually hit.

The second part that was surprisingly elegant was access control.
While sqldoom itself has about 110 tables and just over 100 functions,
the four player roles are only allowed to interact with it through a few well-defined API functions.
We just revoke access to everything else!

The `input` function that takes input from a player is a good example (defined in `sql/runtime/functions/42_api.sql`):

```sql
CREATE OR REPLACE FUNCTION api_input(
  p_fwd real, p_strafe real, p_run boolean, p_turn real,
  p_fire boolean, p_weapon integer, p_use boolean) RETURNS integer
LANGUAGE cedarscript SECURITY DEFINER AS $doom$
INSERT INTO mp_inputs
SELECT mp.map_id, mp.player_thing_id,
       LEAST(1.0, GREATEST(-1.0, COALESCE(p_fwd, 0)))::real,
       LEAST(1.0, GREATEST(-1.0, COALESCE(p_strafe, 0)))::real,
       [...]
FROM mp_players mp WHERE mp.role_name = session_user::text;
return 1;
$doom$;
```

While the *function* is allowed to make changes to tables (`security definer`), the player is only allowed to call the function.

Multiplayer performance is also surprisingly good: 3 cores per client give stable 35 FPS, and the game tic still stays well below budget.
Add an additional core for the tic driver and a 16 core machine is well equipped to run an original `-altdeath` doom deathmatch.

## How to Run it Yourself

You need three things:
1. [CedarDB Community Edition](https://cedardb.com/docs/community_edition/),
2. Python with `psycopg2` and `pygame`,
3. and a Doom IWAD which I can't give you. The shareware doom1.wad is freely redistributable (`apt install doom-wad-shareware`) and is enough to play episode 1, and the retail WADs work if you own them.

Import an episode into a running CedarDB. This installs the schema and the
catalogs, loads the WAD and renders its music, and takes about 18 seconds:

```sh
python3 wad_loader.py doom1.wad --dsn "postgresql://postgres:secret@localhost:5432/postgres"
```

Then play it:

```sh
DB_DSN="dbname=postgres user=postgres host=localhost port=5432" python3 doom_client.py
```

For deathmatch, hand out a role per player, start the referee that owns the
35 Hz clock, and serve the browser client:

```sh
python3 scripts/add_player.py "$OWNER_DSN" alice            # prints a password
DB_DSN="$OWNER_DSN" MAP_ID=1 SKILL=2 python3 doom_server.py
DOOM_WEB_PORT=8080 DOOM_WEB_TARGETS="127.0.0.1:5432" python3 doom_web.py
```

`SKILL`, `ALTDEATH`, `MONSTERS`, `TIMER_MINUTES` and `ROTATION` are read from
the environment by `doom_server.py`.

## Testing
While there aren't any formal unit tests, this repo has some smoke tests:

```sh
python3 scripts/all_maps_smoke.py "$DSN"             # every map: reset, spawn, a scripted minute, a frame
python3 scripts/determinism_check.py --dsn "$DSN"    # the same input twice -> the same world hash
python3 scripts/mp_acl_check.py "$OWNER" "$P1" "$P2" # what a player role can and cannot do
```
The determinism check is important for two reasons: 
1) SQL has set based semantics, and sets are unordered by default. So it's important to add an explicit `order by` whenever ordering actually is required.
2) Replays only work when the math is deterministic. This is why we use a deterministic random function with
the seed derived from the current game state (like python) and do fixed point math for damage calculation etc.

## License

Copyright (C) 2026 CedarDB GmbH. SQLDoom is free software under the GNU
General Public License, version 2 or later; see [LICENSE](LICENSE). It is a
port of the Doom engine, which id Software released under the same license.

No WAD is included and none may be: `doomu.wad` is the retail game, and the
shareware `doom1.wad` stays under id Software's shareware terms.
