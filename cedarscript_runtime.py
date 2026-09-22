"""Install the checked-in CedarScript runtime definitions."""

from pathlib import Path


ROOT = Path(__file__).resolve().parent / "sql" / "runtime" / "functions"

RUNTIME_FILES = (
    # Doom's random number table. Everything that rolls a die uses it,
    # so it has to exist before any of them are defined.
    "00_prandom.sql",
    "01_constants.sql",
    "02_geometry.sql",
    "03_weapon_decision.sql",
    "04_reset_stage.sql",
    "05_spawn_player.sql",
    "06_finish_level.sql",
    "07_cheat_arsenal.sql",
    "08_cs_begin.sql",
    "09_cs_clock.sql",
    "10_cs_plan.sql",
    "11_cs_use.sql",
    "12_cs_activate_specials.sql",
    "13_cs_doors.sql",
    "14_cs_movement_mode.sql",
    "15_cs_move.sql",
    "16_cs_turn.sql",
    "17_cs_secret.sql",
    "18_cs_cross.sql",
    "19_cs_pickups.sql",
    "20_cs_weapon_state.sql",
    "21_cs_weapon.sql",
    "22_cs_hitscan_fire.sql",
    "23_cs_hitscan_apply.sql",
    "24_cs_projectiles.sql",
    "25_cs_sound.sql",
    # Views the monster stages share; installed before them.
    "25a_monster_views.sql",
    "26_cs_monsters.sql",
    "27_cs_item_respawn.sql",
    # Installed before the orchestrator that calls it.
    "28_cs_sector_fx.sql",
    "29_cs_thing_physics.sql",
    "30_carry_player.sql",
    "31_menu.sql",
    "32_save_load.sql",
    "33_intermission.sql",
    "34_cs_death.sql",
    "35_cs_boss.sql",
    "36_finale.sql",
    "37_cs_discover.sql",
    "38_cheats.sql",
    # Deathmatch helpers (respawn, match setup, poses, frags) come before the
    # tic that calls them; the deathmatch tic itself lives with the core.
    "39_mp.sql",
    "40_run_game_tic.sql",
    # Demo, attract-loop and level-flow state machines, on top of everything.
    "41_flow.sql",
    # The deathmatch server's player API: SECURITY DEFINER functions. The
    # api_* views are generated from sql/client by install_api_views.
    "42_api.sql",
    # Renderer helpers. Nothing above depends on them; sql/renderer.sql does.
    "43_render_light.sql",
    # The automap camera, which both clients used to keep themselves.
    "44_automap_view.sql",
)


def runtime_paths():
    """Return the CedarScript definitions in dependency order."""
    paths = tuple(ROOT / filename for filename in RUNTIME_FILES)
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        raise FileNotFoundError(
            "missing CedarScript runtime definitions: " + ", ".join(missing)
        )
    return paths


def install_cedarscript_runtime(cur):
    """Create or replace every SQL-owned runtime object."""
    for path in runtime_paths():
        cur.execute(path.read_text(encoding="utf-8"))
    install_api_views(cur)


CLIENT_SQL = Path(__file__).resolve().parent / "sql" / "client"

# The player-facing read API is the client's own SQL, re-pointed at the
# caller: wherever a client statement takes (map_id, player_thing_id) as
# parameters, the view resolves them from mp_players by session_user instead.
# Generated from the same files the single-player client prepares, so the two
# cannot drift apart. A view runs with its owner's rights, which is what lets
# a role with no table grants read exactly its own player's slice.
ME = ("(SELECT mp.map_id FROM mp_players mp WHERE mp.role_name = session_user::text)",
      "(SELECT mp.player_thing_id FROM mp_players mp WHERE mp.role_name = session_user::text)")


def _client(name):
    return (CLIENT_SQL / name).read_text(encoding="utf-8").strip().rstrip(";")


def api_view_definitions():
    """(view name, SELECT text) for every player-readable view."""
    me_map, me_player = ME
    views = []
    # The caller's own player_state row: what the client resyncs from and what
    # the camera statement interpolates over.
    views.append(("api_player_state",
                  "SELECT ps.* FROM player_state ps JOIN mp_players mp "
                  "ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id "
                  "WHERE mp.role_name = session_user::text"))
    # The per-tic snapshot. Menus and demos are single-player, so the
    # screen_state columns are constants here.
    snap = _client("game_tick_finish.sql")
    snap = snap.replace(
        "  SELECT * FROM game_tic_commands\n  WHERE map_id=$1::int AND player_thing_id=$2::int",
        "  SELECT g.* FROM game_tic_commands g JOIN mp_players mp\n"
        "    ON mp.map_id = g.map_id AND mp.player_thing_id = g.player_thing_id\n"
        "  WHERE mp.role_name = session_user::text")
    snap = snap.replace("  ss.screen,\n  (ss.demo_playing IS NOT NULL) AS demo_active",
                        "  'game'::text AS screen,\n  FALSE AS demo_active")
    snap = snap.replace("\nCROSS JOIN screen_state ss", "")
    assert "$1" not in snap and "screen_state" not in snap, "game_tick_finish.sql changed shape"
    views.append(("api_snapshot", snap))
    # Sounds positioned for this listener; the client filters by event_id.
    ev = _client("sound_events.sql")
    ev = ev.replace("WHERE t.map_id=$1 AND t.id=$2", f"WHERE t.map_id={me_map} AND t.id={me_player}")
    ev = ev.replace("  WHERE e.map_id=$3 AND e.event_id>$4\n", f"  WHERE e.map_id={me_map}\n")
    ev = ev.replace("\nORDER BY event_id", "")
    assert "$" not in ev, "sound_events.sql changed shape"
    views.append(("api_sound_events", ev))
    loops = _client("sound_loops.sql")
    loops = loops.replace("  SELECT $1::int AS map_id,$2::int AS player_thing_id",
                          f"  SELECT {me_map} AS map_id,{me_player} AS player_thing_id")
    assert "$" not in loops, "sound_loops.sql changed shape"
    views.append(("api_sound_loops", loops))
    views.append(("api_stage_music",
                  _client("stage_music.sql").replace("WHERE mm.map_id=$1", f"WHERE mm.map_id={me_map}")))
    match_map = "(SELECT m.map_id FROM mp_match m)"
    views.append(("api_map_lines",
                  _client("automap.sql").replace("WHERE ld.map_id=%s", f"WHERE ld.map_id={match_map}")))
    views.append(("api_stages", _client("stages.sql")))
    views.append(("api_map_geometry",
                  "SELECT x1, y1, x2, y2, ssector_id, (bsec IS NULL) AS solid "
                  f"FROM render_segs WHERE map_id = {match_map}"))
    # PLAYPAL, for clients that take the frame as palette indices
    # (api_frame_idx_slot<n>): every index COLORMAP can map to, in each of the
    # fourteen palettes.
    views.append(("api_palettes",
                  "SELECT pal, mapped_index AS idx, MIN(r) AS r, MIN(g) AS g, MIN(b) AS b "
                  "FROM colormap_rgb GROUP BY pal, mapped_index"))
    # Where the match is: which map, how long it has left, whether it is
    # between maps and what comes next. Public to every player.
    views.append(("api_match",
                  "SELECT m.state, m.map_id, ma.name AS map_name, m.timer_tics, m.altdeath, m.monsters, "
                  "m.maps_played, "
                  "(SELECT COALESCE(MAX(ps.level_tics), 0) FROM player_state ps JOIN mp_players mp "
                  " ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id "
                  " WHERE mp.map_id = m.map_id) AS level_tics, "
                  "GREATEST(0, COALESCE(EXTRACT(EPOCH FROM (m.intermission_until - now())), 0))::int "
                  " AS intermission_seconds, "
                  "COALESCE((SELECT r.map_name FROM mp_rotation r WHERE r.position > "
                  "  COALESCE((SELECT r2.position FROM mp_rotation r2 WHERE r2.map_name = ma.name), -1) "
                  "  ORDER BY r.position LIMIT 1), "
                  " (SELECT r.map_name FROM mp_rotation r ORDER BY r.position LIMIT 1), ma.name) AS next_map, "
                  # the lobby queue: how many wait, and how many arrived before the caller
                  "(SELECT count(*) FROM mp_waiting w WHERE EXTRACT(EPOCH FROM (now() - w.last_seen)) <= 5) AS waiting, "
                  "(SELECT count(*) FROM mp_waiting w JOIN mp_waiting me ON me.role_name = session_user::text "
                  " WHERE w.since < me.since AND EXTRACT(EPOCH FROM (now() - w.last_seen)) <= 5) AS ahead_of_me, "
                  # the seat limit while others wait, and how long the caller has held one
                  "m.hold_seconds, "
                  "(SELECT EXTRACT(EPOCH FROM (now() - mp.claimed_at))::int FROM mp_players mp "
                  " WHERE mp.map_id = m.map_id AND mp.role_name = session_user::text) AS my_seat_seconds "
                  "FROM mp_match m JOIN maps ma ON ma.map_id = m.map_id"))
    views.append(("api_tic",
                  "SELECT tic_ms, tic_p90_ms, tic_max_ms, tics, dropped, interval_seconds, "
                  "EXTRACT(EPOCH FROM (now() - updated_at))::real AS age_seconds "
                  "FROM api_tic_stats WHERE id = 1"))
    # Who is in and how they are doing; public to every player.
    views.append(("api_scoreboard",
                  "SELECT mp.slot, COALESCE(mp.display_name, mp.role_name) AS role_name, "
                  "(mp.role_name IS NOT NULL) AS connected, "
                  "ps.frags, ps.health, ps.alive, mp.role_name AS login FROM mp_players mp "
                  "JOIN player_state ps ON ps.map_id = mp.map_id "
                  "AND ps.player_thing_id = mp.player_thing_id ORDER BY mp.slot"))
    return views


def install_api_views(cur):
    cur.execute("CREATE TABLE IF NOT EXISTS api_tic_stats ("
                "id int PRIMARY KEY, updated_at timestamptz NOT NULL, "
                "tic_ms real NOT NULL, tic_p90_ms real NOT NULL, tic_max_ms real NOT NULL, "
                "tics int NOT NULL, dropped int NOT NULL, interval_seconds real NOT NULL)")
    for name, select in api_view_definitions():
        cur.execute(f"CREATE OR REPLACE VIEW {name} AS {select}")
    _install_api_automap(cur)
    _install_api_camera(cur)
    # Replacing a view drops its grants: hand the API back to every
    # provisioned player role (the table exists once the schema is in).
    # The overview for spectators, and for the bots (scripts/bots.mjs), which
    # steer by it; the same positions the console's map shows everyone.
    cur.execute("CREATE OR REPLACE VIEW api_things_spawn AS "
                "SELECT id, map_id, spawn_x, spawn_y, spawn_angle, type, flags FROM things")
    cur.execute(
        "CREATE OR REPLACE VIEW api_things_live AS "
        "SELECT t.map_id, t.id AS thing_id, 'monster'::text AS kind, d.name, "
        "       t.x::real AS x, t.y::real AS y, t.angle::real AS angle, h.alive "
        "FROM things t "
        "JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill "
        "JOIN thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id "
        "WHERE h.alive "
        "UNION ALL "
        "SELECT ps.map_id, ps.player_thing_id, 'player'::text, COALESCE(mp.display_name, mp.role_name), "
        "       ps.position_x::real, ps.position_y::real, ps.view_angle::real, ps.alive "
        "FROM player_state ps "
        "JOIN mp_players mp ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id "
        "WHERE mp.role_name IS NOT NULL")
    cur.execute("CREATE TABLE IF NOT EXISTS api_roles (role_name TEXT PRIMARY KEY)")
    cur.execute("SELECT role_name FROM api_roles ORDER BY role_name")
    for (role,) in cur.fetchall():
        grant_player_api(cur, role)
    cur.execute("CREATE TABLE IF NOT EXISTS api_spectator_roles (role_name TEXT PRIMARY KEY)")
    cur.execute("SELECT role_name FROM api_spectator_roles ORDER BY role_name")
    for (role,) in cur.fetchall():
        grant_spectator_api(cur, role)
    close_api_to_public(cur)


def close_api_to_public(cur):
    failed = []
    for statement in API_ROLES_GRANTS:
        if "ON FUNCTION" not in statement:
            continue
        signature = statement.split("ON FUNCTION ", 1)[1].split(" TO ", 1)[0]
        try:
            cur.execute(f"REVOKE EXECUTE ON FUNCTION {signature} FROM PUBLIC")
        except Exception as exc:  # noqa: BLE001 - reported, not hidden
            failed.append(f"{signature}: {str(exc).strip().splitlines()[0]}")
    if failed:
        print("[runtime] could not revoke PUBLIC execute on: " + "; ".join(failed), flush=True)
    return failed


def _install_api_camera(cur):
    """api_camera(alpha): client/camera_pose.sql over the caller's own player,
    written straight into the slot's pose, so a frame is camera + frame view
    in one round trip and the client holds no camera arithmetic."""
    body = _client("camera_pose.sql")
    body = body.replace(
        "FROM player_state ps\n",
        "FROM player_state ps\nJOIN mp_players me ON me.map_id = ps.map_id "
        "AND me.player_thing_id = ps.player_thing_id AND me.role_name = session_user::text\n")
    body = body.replace("\nWHERE ps.map_id = $1 AND ps.player_thing_id = $2", "")
    body = body.replace("$3", "p_alpha")
    assert "$" not in body and "me.role_name" in body, "camera_pose.sql changed shape"
    cur.execute(
        "CREATE OR REPLACE FUNCTION api_camera(p_alpha double precision) RETURNS integer "
        "LANGUAGE cedarscript SECURITY DEFINER AS $api$\n"
        "let mut playing = false;\n"
        "SELECT (m.state = 'playing') AS x FROM mp_match m { playing = x; }\n"
        "if playing {\n"
        "UPDATE mp_players mp SET pose_x = c.x, pose_y = c.y, pose_z = c.z, "
        "pose_angle = c.angle, last_seen = GREATEST(COALESCE(mp.last_seen, now()), now())\nFROM (\n" + body + "\n) c\n"
        "WHERE mp.role_name = session_user::text;\n}\nreturn 1;\n$api$")


def _install_api_automap(cur):
    cur.execute("DROP FUNCTION IF EXISTS api_automap(double precision, "
                "double precision, double precision, boolean, integer, boolean)")
    body = _client("render_automap.sql")
    for src, dst in (("$1", "m"), ("$2", "p")):
        body = body.replace(src, dst)
    slot = ("let mut m = 0; let mut p = 0;\n"
            "SELECT mp.map_id AS a, mp.player_thing_id AS b FROM mp_players mp "
            "WHERE mp.role_name = session_user::text { m = a; p = b; }\n")
    cur.execute(
        "CREATE OR REPLACE FUNCTION api_automap() "
        "RETURNS bytea LANGUAGE cedarscript SECURITY DEFINER AS $api$\n"
        "let mut result = NULL::bytea;\n" + slot
        + body + "\n{ result = frame_rgb; }\nreturn result;\n$api$")
    for name, params, call in (
        ("pan", "p_dx double precision, p_dy double precision", "m, p, p_dx, p_dy"),
        ("zoom", "p_factor double precision", "m, p, p_factor"),
        ("toggle", "p_what text",
         "m, p, (CASE WHEN p_what IN ('follow','grid') THEN p_what ELSE 'none' END)"),
        ("fit", "", "m, p"),
    ):
        cur.execute(
            f"CREATE OR REPLACE FUNCTION api_automap_{name}({params}) "
            "RETURNS integer LANGUAGE cedarscript SECURITY DEFINER AS $api$\n"
            + slot + f"doom_automap_{name}({call});\nreturn 1;\n$api$")


API_ROLES_GRANTS = (
    "GRANT SELECT ON sound_assets TO {role}",
    "GRANT SELECT ON api_player_state, api_snapshot, api_sound_events, "
    "api_sound_loops, api_stage_music, api_map_lines, api_stages, api_map_geometry, "
    "api_palettes, api_scoreboard, api_match, api_things_live TO {role}",
    "GRANT EXECUTE ON FUNCTION api_slot() TO {role}",
    "GRANT EXECUTE ON FUNCTION api_camera(double precision) TO {role}",
    "GRANT EXECUTE ON FUNCTION api_join() TO {role}",
    "GRANT EXECUTE ON FUNCTION api_input(real,real,boolean,real,boolean,integer,boolean) TO {role}",
    "GRANT EXECUTE ON FUNCTION api_weapon_slot(integer) TO {role}",
    "GRANT EXECUTE ON FUNCTION api_weapon_cycle(integer) TO {role}",
    "GRANT EXECUTE ON FUNCTION api_set_name(text) TO {role}",
    "GRANT EXECUTE ON FUNCTION api_automap() TO {role}",
    "GRANT EXECUTE ON FUNCTION api_automap_pan(double precision,double precision) TO {role}",
    "GRANT EXECUTE ON FUNCTION api_automap_zoom(double precision) TO {role}",
    "GRANT EXECUTE ON FUNCTION api_automap_toggle(text) TO {role}",
    "GRANT EXECUTE ON FUNCTION api_automap_fit() TO {role}",
)


def grant_player_api(cur, role):
    """Everything a player role may touch. Nothing else is granted. The role
    is remembered so a runtime reinstall re-grants it."""
    for statement in API_ROLES_GRANTS:
        cur.execute(statement.format(role=role))
    # The definer functions run as their owner, but nextval on a sequence is
    # still checked against the caller (the input queue's, the sound events'
    # behind a respawn). USAGE only hands out numbers; the tables stay closed.
    cur.execute("SELECT sequence_name FROM information_schema.sequences ORDER BY 1")
    for (sequence,) in cur.fetchall():
        cur.execute(f"GRANT USAGE ON SEQUENCE {sequence} TO {role}")
    for view in frame_views_present(cur):
        cur.execute(f"GRANT SELECT ON {view} TO {role}")
    cur.execute("CREATE TABLE IF NOT EXISTS api_roles (role_name TEXT PRIMARY KEY)")
    cur.execute("INSERT INTO api_roles (role_name) VALUES (%s) ON CONFLICT DO NOTHING", (role,))


# What a read-only spectator may SELECT
SPECTATOR_RELATIONS = (
    # the WAD
    "wads", "maps", "vertexes", "sectors", "sidedefs", "linedefs", "segs", "ssectors",
    "nodes", "node_children", "blockmaps", "walltex_meta", "flat_textures",
    "sprite_frames", "sprite_lumps", "colormap_rgb", "map_music",
    # the catalogues
    "thing_sprite_defs", "pickup_messages", "chase_dir_defs", "thing_role_defs",
    "thing_blocking_defs", "projectile_defs", "thing_combat_defs", "weapon_defs",
    "weapon_frames", "doom_constants", "thing_ai_frames", "effect_sprite_defs",
    "ammo_defs", "pickup_defs", "level_pars", "boss_actions", "finale_defs",
    "line_special_defs", "sector_special_defs", "thing_sound_defs",
    # the match, without anyone's position
    "mp_match", "mp_rotation", "level_stats", "tic_trace", "item_respawns",
    "sector_movers",
    # the public views, and the live overview for spectators
    "api_match", "api_scoreboard", "api_palettes", "api_things_spawn", "api_things_live", "mp_stats",
    "api_tic",
)


def grant_spectator_api(cur, role):
    """SELECT on the spectator relations, nothing else."""
    cur.execute("SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'")
    present = {row[0] for row in cur.fetchall()}
    granted = []
    for relation in SPECTATOR_RELATIONS:
        if relation not in present:
            continue
        cur.execute(f"GRANT SELECT ON {relation} TO {role}")
        granted.append(relation)
    for relation in ("pg_sys_cpu_usage_info", "pg_sys_memory_info"):
        try:
            cur.execute(f"GRANT SELECT ON {relation} TO {role}")
            granted.append(relation)
        except Exception:  # noqa: BLE001 - the Overview then shows its fallback
            pass
    cur.execute("CREATE TABLE IF NOT EXISTS api_spectator_roles (role_name TEXT PRIMARY KEY)")
    cur.execute("INSERT INTO api_spectator_roles (role_name) VALUES (%s) ON CONFLICT DO NOTHING",
                (role,))
    return granted


def frame_views_present(cur):
    """The per-slot frame views a referee has installed, if any."""
    cur.execute("SELECT table_name FROM information_schema.tables "
                "WHERE table_name LIKE 'api_frame_%' ORDER BY table_name")
    return [row[0] for row in cur.fetchall()]


def frame_view_body(map_id, player_thing_id, skill, slot, indexed):
    """The renderer as a view body for one slot, with the match's constants
    folded in (the same folding prepare_renderer does), the camera read from
    the slot's mp_players pose (api_camera writes it), and the whole thing
    gated on the caller holding
    the slot. `indexed` makes it emit one COLORMAP-mapped palette index per
    pixel behind a leading palette-number byte (64001 bytes) instead of RGB:
    the browser client applies PLAYPAL itself."""
    body = (Path(__file__).resolve().parent / "sql" / "renderer.sql").read_text(encoding="utf-8")
    body = body.strip().rstrip(";")
    body = body.replace("$1", str(int(map_id))).replace("$2", str(int(player_thing_id))).replace("$3", str(int(skill)))
    mine = (f"mp.map_id = {int(map_id)} AND mp.slot = {int(slot)} "
            "AND mp.role_name = session_user::text")
    a = body.index("), pos AS (")
    b = body.index("), frame_clock AS (")
    body = body[:a] + ("), pos AS (\n    SELECT mp.pose_x::float8 AS x, mp.pose_y::float8 AS y, "
                       "mp.pose_z::float8 AS z, mp.pose_angle::float8 AS angle\n"
                       f"    FROM mp_players mp WHERE {mine}\n") + body[b:]
    # The renderer's final projection: the aggregate of the pixel column and
    # the CTE it reads. Two shapes are known (before and after the framebuffer
    # union of 2026-09-13); the leading palette byte is spliced in front of
    # whichever is present.
    tails = ("SELECT string_agg(px,''::bytea ORDER BY y,g) AS frame_rgb\nFROM packed",
             "SELECT string_agg(rgb, ''::bytea ORDER BY pix) AS frame_rgb\nFROM framebuffer")
    found = [t for t in tails if body.count(t) == 1]
    assert len(found) == 1, "renderer.sql changed its final projection"
    tail = found[0]
    aggregate, source = tail[len("SELECT "):].split(" AS frame_rgb\nFROM ")
    if indexed:
        subs = (
            ("SELECT cm.level, cm.palette_index, cm.rgb\n  FROM colormap_rgb cm",
             "SELECT cm.level, cm.palette_index, set_byte('\\x00'::bytea, 0, cm.mapped_index::int) AS rgb\n  FROM colormap_rgb cm"),
            ("CASE WHEN ap.pal = 0 THEN s.rgb ELSE barcm.rgb END,\n                  s.rgb) AS rgb",
             "set_byte('\\x00'::bytea, 0, s.palette_index::int)) AS rgb"),
            ("'\\x000000'::bytea", "'\\x00'::bytea"),
        )
        for src, dst in subs:
            assert src in body, f"renderer.sql lost the colour anchor {src[:40]!r}"
            body = body.replace(src, dst)
        tail_new = ("SELECT (SELECT set_byte('\\x00'::bytea, 0, ap.pal::int) FROM active_palette ap) "
                    f"|| {aggregate} AS frame_rgb\nFROM {source}")
    else:
        tail_new = tail
    body = body.replace(tail, tail_new + f"\nWHERE EXISTS (SELECT 1 FROM mp_players mp WHERE {mine})")
    assert "$" not in body, "renderer.sql grew a parameter"
    return body


def frame_view_name(slot, map_id, indexed):
    return f"api_frame_{'idx_' if indexed else ''}slot{int(slot)}_m{int(map_id)}"


def install_slot_frame_views(cur, map_id, slot, player_thing_id, skill):
    """api_frame_slot<n>_m<map> (RGB) and api_frame_idx_slot<n>_m<map> (palette
    indices) for one slot on one map, granted to every provisioned player
    role: only the role holding the slot, while the match is on that map,
    gets a frame out of them. One pair per map of the rotation is created
    when the referee starts and never replaced while it runs: a view DDL
    invalidates every prepared statement on the server, and recompiling the
    tic and every client's frame statement costs seconds each time."""
    views = []
    for indexed in (False, True):
        view = frame_view_name(slot, map_id, indexed)
        cur.execute(f"CREATE OR REPLACE VIEW {view} AS "
                    + frame_view_body(map_id, player_thing_id, skill, slot, indexed))
        views.append(view)
    cur.execute("CREATE TABLE IF NOT EXISTS api_roles (role_name TEXT PRIMARY KEY)")
    cur.execute("SELECT role_name FROM api_roles ORDER BY role_name")
    for (role,) in cur.fetchall():
        for view in views:
            cur.execute(f"GRANT SELECT ON {view} TO {role}")
    return views


def install_match_frame_views(cur, map_ids, skill):
    """The frame views for every map the match can visit, up front. Slot n on
    a map is the player-n start's Thing, the same rule doom_mp_start uses.
    Returns {map_id: {slot: thing}}."""
    layout = {}
    for map_id in map_ids:
        cur.execute("SELECT t.type, MIN(t.id) FROM things t WHERE t.map_id=%s AND t.type IN (1,2,3,4) "
                    "GROUP BY t.type ORDER BY t.type", (map_id,))
        slots = {int(slot): int(thing) for slot, thing in cur.fetchall()}
        for slot, thing in slots.items():
            install_slot_frame_views(cur, map_id, slot, thing, skill)
        layout[int(map_id)] = slots
    return layout
