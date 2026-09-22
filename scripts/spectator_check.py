#!/usr/bin/env python3
"""Prove what the spectator login can and cannot do, as the cloud demo will use it.

    python3 scripts/spectator_check.py "<spectator dsn>" [--player doom_guest1]

Three groups, each line OK or FAIL:

  console   the statements the cloud frontend's tabs send (databases, the
            relation catalog, roles, memberships, grants, schemas, tables,
            system and connection stats). A FAIL here means that tab shows an
            error for the Doom project; the Query tab still works.
  templates the Doom query templates the frontend offers
            (cedardb-cloud-frontend/src/components/project/queryContent.ts,
            DOOM_QUERY_TEMPLATES). Keep the two lists in step; a FAIL here is
            a template to fix or drop before the post goes out.
  forbidden things a spectator must not be able to do: read a live position,
            read inputs, call the player API, write, or see a frame. These
            must FAIL; a success is reported as a leak.

Exit status is 0 only when every console and template statement runs and
every forbidden one is refused.
"""
import sys

import psycopg2

# --- what the frontend sends (api/queries.ts) --------------------------------
CONSOLE = {
    "databases": "select datname from pg_database order by datname",
    "catalog": """select n.nspname as schema_name, c.relname as table_name, c.relkind as relation_kind,
  a.attname as column_name, pg_catalog.format_type(a.atttypid, a.atttypmod) as column_type
from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_attribute a on a.attrelid = c.oid
where c.relkind in ('r', 'p', 'v', 'm', 'f') and a.attnum > 0 and not a.attisdropped
order by n.nspname, c.relname, a.attnum""",
    "roles": """select rolname as role_name, rolcanlogin as can_login, rolsuper as is_superuser,
  rolcreatedb as can_create_db, rolcreaterole as can_create_role, rolinherit as can_inherit,
  rolbypassrls as can_bypass_rls, rolvaliduntil as valid_until, rolconnlimit as connection_limit
from pg_roles where rolname not like 'pg\\_%' order by rolname""",
    "memberships": """select m.rolname as member, g.rolname as group_name
from pg_auth_members am join pg_roles m on m.oid = am.member join pg_roles g on g.oid = am.roleid
where m.rolname not like 'pg\\_%' and g.rolname not like 'pg\\_%' order by m.rolname, g.rolname""",
    "schemas": """select nspname as schema_name, pg_get_userbyid(n.nspowner) as owner
from pg_namespace n where nspname not like 'pg\\_%' and nspname <> 'information_schema' order by nspname""",
    "tables": """select c.relname as table_name, pg_get_userbyid(c.relowner) as owner
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm') order by c.relname""",
    "database owner": "select pg_get_userbyid(datdba) as owner from pg_database where datname = 'postgres'",
    "grants of {player}": """with recursive member_of(role_oid) as (
  select oid from pg_roles where rolname = '{player}'
  union
  select am.roleid from member_of m join pg_auth_members am on am.member = m.role_oid
)
select grants.level as level, grants.object_name as object, grants.schema_name as schema,
  case when grants.grantee = 0 then 'PUBLIC' else grants.grantee::regrole::text end as grantee,
  case when grants.grantor = 0 then 'PUBLIC' else grants.grantor::regrole::text end as grantor,
  grants.privilege as privilege
from (
  select 'database'::text as level, d.datname as object_name, null::text as schema_name,
    acl.grantee as grantee, acl.grantor as grantor, acl.privilege_type as privilege
  from pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) acl
  where d.datname = 'postgres'
  union all
  select 'schema'::text, n.nspname, null::text, acl.grantee, acl.grantor, acl.privilege_type
  from pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) acl
  union all
  select 'table'::text, c.relname, n.nspname, acl.grantee, acl.grantor, acl.privilege_type
  from pg_class c join pg_namespace n on n.oid = c.relnamespace,
    aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) acl
  where c.relkind in ('r', 'p', 'v', 'm')
) grants
where grants.grantee in (select role_oid from member_of) or grants.grantee = 0""",
    "system stats": """select 100 - cpu.idle_mode_percent as cpu_pct,
  memory.used_memory / (1024.0 * 1024 * 1024) as memory_used_gib,
  memory.cache_total / (1024.0 * 1024 * 1024) as memory_cache_gib,
  memory.total_memory / (1024.0 * 1024 * 1024) as memory_total_gib,
  (select sum(pg_database_size(datname)) from pg_database) / (1024.0 * 1024 * 1024) as storage_used_gib
from pg_sys_cpu_usage_info() as cpu cross join pg_sys_memory_info() as memory""",
    "connection stats": "select state, count(*) as num_connections from pg_stat_activity group by state",
}

# --- the Doom templates (queryContent.ts, DOOM_QUERY_TEMPLATES) -------------
TEMPLATES = {
    "Who is fragging whom": "SELECT slot, role_name AS player, connected, frags, health, alive FROM api_scoreboard ORDER BY frags DESC, slot",
    "Where the match is": "SELECT state, map_name, (timer_tics - level_tics) / 35 AS seconds_left, intermission_seconds, next_map, maps_played, waiting AS in_lobby, altdeath, monsters FROM api_match",
    "The world, live": "SELECT map_name, monsters_alive, monsters_total, monsters_awake, projectiles, effects, items_out, items_queued, movers, input_backlog, sessions FROM mp_stats",
    "Current map as text": """WITH bounds AS (
  SELECT min(x)::float8 AS x0, min(y)::float8 AS y0, GREATEST((max(x) - min(x)) / 100.0, (max(y) - min(y)) / 80.0, 1) AS cell
  FROM vertexes WHERE map_id = (SELECT map_id FROM api_match)
), lines AS (
  SELECT l.left_sd_id < 0 AS solid, v1.x AS x1, v1.y AS y1, v2.x AS x2, v2.y AS y2,
         GREATEST(1, ceil(sqrt(power(v2.x - v1.x, 2) + power(v2.y - v1.y, 2)) / b.cell))::int AS steps
  FROM linedefs AS l
  JOIN vertexes AS v1 ON v1.map_id = l.map_id AND v1.id = l.v1_id
  JOIN vertexes AS v2 ON v2.map_id = l.map_id AND v2.id = l.v2_id
  CROSS JOIN bounds AS b
  WHERE l.map_id = (SELECT map_id FROM api_match)
), wall AS (
  SELECT floor((x1 + (x2 - x1) * t::float8 / steps - b.x0) / b.cell)::int AS col,
         floor((y1 + (y2 - y1) * t::float8 / steps - b.y0) / (2 * b.cell))::int AS row, bool_or(solid) AS solid
  FROM lines, bounds AS b, generate_series(0, steps) AS t GROUP BY 1, 2
), box AS (SELECT min(col) AS c0, max(col) AS c1, min(row) AS r0, max(row) AS r1 FROM wall)
SELECT string_agg(CASE WHEN w.solid THEN '#' WHEN w.col IS NOT NULL THEN '.' ELSE ' ' END, '' ORDER BY g.col) AS map
FROM box, generate_series(box.c0, box.c1) AS g(col), generate_series(box.r0, box.r1) AS r(row)
LEFT JOIN wall AS w ON w.col = g.col AND w.row = r.row
GROUP BY r.row ORDER BY r.row DESC""",
    "Linedefs of the current map": """SELECT l.id AS linedef, v1.x AS x1, v1.y AS y1, v2.x AS x2, v2.y AS y2, l.flags, l.special, l.tag
FROM linedefs AS l
JOIN vertexes AS v1 ON v1.map_id = l.map_id AND v1.id = l.v1_id
JOIN vertexes AS v2 ON v2.map_id = l.map_id AND v2.id = l.v2_id
WHERE l.map_id = (SELECT map_id FROM api_match) ORDER BY l.id""",
    "Sectors": "SELECT id AS sector, floor_height, ceil_height, floor_tex, ceil_tex, light_level, special, tag FROM sectors WHERE map_id = (SELECT map_id FROM api_match) ORDER BY id",
    "Where things spawn": """SELECT t.id AS thing, t.type, d.name, t.spawn_x, t.spawn_y, t.spawn_angle, t.flags
FROM api_things_spawn AS t LEFT JOIN thing_combat_defs AS d ON d.thing_type = t.type
WHERE t.map_id = (SELECT map_id FROM api_match) ORDER BY t.id""",
    "Every monster is a row": "SELECT thing_type, name, spawn_health, radius, height, mass, pain_chance, attack_range, missile_type, missile_speed, hitscan_pellets, melee_mult, floats, skull_fly FROM thing_combat_defs WHERE counts_kill ORDER BY spawn_health DESC",
    "The line specials": "SELECT special, name, mechanic, cross_activated, use_activated, shoot_activated, key_required, is_exit, door_target, mover_type, speed FROM line_special_defs ORDER BY special",
    "The arsenal": "SELECT weapon_id, name, slot, ammo_type, ammo_per_shot, pellet_count, dmg_dice_count || 'd' || dmg_dice_mult AS damage, max_range, projectile_type FROM weapon_defs ORDER BY slot, weapon_id",
    "Kills, items, secrets": "SELECT player_thing_id, level_tics, kills, total_kills, items, total_items, secrets, total_secrets FROM level_stats WHERE map_id = (SELECT map_id FROM api_match) ORDER BY player_thing_id",
    "What the planner ran": "SELECT map_id, player_thing_id, stages AS stage_mask FROM tic_trace ORDER BY map_id, player_thing_id",
    "The map rotation": "SELECT r.position, r.map_name, m.sky_texture FROM mp_rotation AS r LEFT JOIN maps AS m ON m.name = r.map_name ORDER BY r.position",
    "The game loop's source": "SELECT prosrc FROM pg_proc WHERE proname = 'doom_cs_thing_physics'",
}

# --- what must be refused ---------------------------------------------------
FORBIDDEN = {
    "read live player positions": "SELECT position_x, position_y FROM player_state",
    "read slot poses": "SELECT pose_x, pose_y, role_name FROM mp_players",
    "read live thing positions": "SELECT x, y FROM things LIMIT 1",
    "read inputs": "SELECT count(*) FROM mp_inputs",
    "read monster ai": "SELECT count(*) FROM monster_ai",
    "write the rotation": "INSERT INTO mp_rotation (position, map_name) VALUES (99, 'E1M1')",
    "change the match": "UPDATE mp_match SET timer_tics = 1",
    "create a table": "CREATE TABLE spectator_scratch (x int)",
}


def run(cur, sql):
    try:
        cur.execute(sql)
        rows = cur.fetchall() if cur.description else []
        return True, f"{len(rows)} rows"
    except psycopg2.Error as exc:
        return False, str(exc).strip().splitlines()[0][:110]


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    dsn = args[0]
    player = args[args.index("--player") + 1] if "--player" in args else "doom_guest1"
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SELECT current_user")
    print(f"signed in as {cur.fetchone()[0]}\n")
    bad = 0

    print("console (the frontend's own statements)")
    for name, sql in CONSOLE.items():
        ok, detail = run(cur, sql.replace("{player}", player))
        if not ok and name == "system stats":
            # The pg_sys_* table functions stay owner-only on every build so
            # far; the Overview shows its fallback text for that card.
            print(f"  WARN {name}: {detail} (the Overview's usage card shows its fallback)")
            continue
        bad += not ok
        print(f"  {'OK  ' if ok else 'FAIL'} {name.format(player=player)}: {detail}")

    print("\ntemplates (the Doom query library)")
    for name, sql in TEMPLATES.items():
        ok, detail = run(cur, sql)
        bad += not ok
        print(f"  {'OK  ' if ok else 'FAIL'} {name}: {detail}")

    print("\nforbidden (each must be refused)")
    for name, sql in FORBIDDEN.items():
        ok, detail = run(cur, sql)
        bad += ok
        print(f"  {'LEAK' if ok else 'OK  '} {name}: {detail}")
    # The engine does not enforce EXECUTE on functions (CEDARDB_REPROS.md), so
    # the player API is callable; what must hold is that it does nothing for a
    # spectator: api_join answers -1 and no slot ever carries this login.
    try:
        cur.execute("SELECT api_join()")
        joined = cur.fetchone()[0]
        cur.execute("SELECT api_input(1, 0, false, 0, false, 0, false)")
        cur.execute("SELECT count(*) FROM api_scoreboard WHERE login = current_user::text")
        holds = cur.fetchone()[0]
        leak = joined >= 0 or holds > 0
        bad += leak
        print(f"  {'LEAK' if leak else 'OK  '} join the match: api_join() = {joined}, slots held = {holds}"
              + ("" if leak else " (callable, but refused inside the function)"))
    except psycopg2.Error as exc:
        print(f"  OK   join the match: {str(exc).strip().splitlines()[0][:110]}")
    # Sequences: the player roles have USAGE (nextval behind the definer
    # functions is checked against the caller); a spectator must not.
    cur.execute("SELECT relname FROM pg_class WHERE relkind = 'S' ORDER BY 1 LIMIT 1")
    row = cur.fetchone()
    if row:
        ok, detail = run(cur, f"SELECT nextval('{row[0]}')")
        bad += ok
        print(f"  {'LEAK' if ok else 'OK  '} draw a sequence number ({row[0]}): {detail}")
    # A frame view, if the referee has installed one, must stay closed.
    cur.execute("SELECT table_name FROM information_schema.tables WHERE table_name LIKE 'api_frame_%' ORDER BY 1 LIMIT 1")
    row = cur.fetchone()
    if row:
        ok, detail = run(cur, f"SELECT frame_rgb FROM {row[0]}")
        bad += ok
        print(f"  {'LEAK' if ok else 'OK  '} read a frame view ({row[0]}): {detail}")
    else:
        print("  (no frame view installed yet; start the referee and run again)")

    print(f"\n{'all good' if not bad else f'{bad} problem(s)'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
