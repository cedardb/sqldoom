# SQL layout

- `schema.sql` defines the database schema installed by `wad_loader.py`.
- `renderer.sql` is the prepared frame renderer.
- `runtime/functions/` contains complete `CREATE OR REPLACE` definitions for
  the SQL-owned CedarScript runtime. Numeric prefixes define installation
  order; `cedarscript_runtime.py` only loads these files.
  A `doom_cs_` prefix means the function is a stage of the 35 Hz tic --
  `doom_run_game_tic` calls exactly those -- so the prefix answers "does this
  run inside the tic", which is what determinism and ordering hang on.
  Everything else is a helper, setup, catalog view, or an entry point the
  client calls between tics. Files are named to match: a `cs_` file holds tic
  stages. `39_mp.sql` is the one exception, grouping the deathmatch feature
  and holding one stage (`doom_cs_player_pose`) among its entry points.
- `loader/` owns static gameplay catalogs and import-time materialization
  functions used by `wad_loader.py`.
- `client/` contains small result projections that `doom_sql.py` prepares for
  the Python client.

Runtime state changes belong in `runtime/functions/`; `client/` queries should
only expose SQL-owned state needed for input, display, or audio.

`scripts/prepared_pipeline_smoke.py --dsn DSN` resets E1M1 in the target
database and verifies catalogs, prepared game tics, projections, and rendering.
Use it only against a disposable or otherwise resettable database.
