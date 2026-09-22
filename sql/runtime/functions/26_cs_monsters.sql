-- One 35 Hz tic for every monster on the map

--   1 noise      the player fired, so sleeping monsters may hear it
--   2 stepping   a chaser is on a frame that moves it
--   4 floater    a cacodemon or lost soul is awake
--   8 chasing    something is in 'see'
--  16 attacking  something landed on an attack frame
--  32 barrel     one of those is a barrel going off
--  64 blast      a barrel or a rocket has a radius to push with
--
CREATE OR REPLACE FUNCTION doom_cs_monster_plan(p_map_id integer) RETURNS bigint
LANGUAGE cedarscript AS $doom$
let mut flags = 0::bigint;
SELECT
  EXISTS (SELECT 1 FROM player_weapons pw
          WHERE pw.map_id=p_map_id AND pw.fired_this_tick) AS noise_due,
  EXISTS (
    SELECT 1 FROM monster_ai ai
    JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
    JOIN thing_ai_frames f ON f.thing_type=t.type AND f.state='see'
      AND f.seq_index=ai.seq_index
    JOIN thing_combat_defs cd ON cd.thing_type=t.type AND NOT cd.explodes
    WHERE ai.map_id=p_map_id AND ai.state='see'
      AND (ai.state_tics=f.tics OR ai.state_tics=FLOOR(f.tics/2.0)::int)
  ) AS stepping_due,
  EXISTS (
    SELECT 1 FROM monster_ai ai
    JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
    JOIN thing_combat_defs d ON d.thing_type=t.type
    WHERE ai.map_id=p_map_id AND d.floats AND ai.state IN ('see','missile')
  ) AS floater_due,
  EXISTS (SELECT 1 FROM monster_ai
          WHERE map_id=p_map_id AND state='see') AS chasing_due,
  EXISTS (SELECT 1 FROM monster_ai
          WHERE map_id=p_map_id AND fired_this_tick) AS attacking_due,
  EXISTS (
    SELECT 1 FROM monster_ai ai
    JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
    JOIN thing_combat_defs cd ON cd.thing_type=t.type AND cd.explodes
    WHERE ai.map_id=p_map_id AND ai.fired_this_tick
  ) AS barrel_due,
  EXISTS (SELECT 1 FROM projectile_impacts
          WHERE map_id=p_map_id AND projectile_type='rocket') AS rocket_due
{
  if noise_due { flags = flags + 1; }
  if stepping_due { flags = flags + 2; }
  if floater_due { flags = flags + 4; }
  if chasing_due { flags = flags + 8; }
  if attacking_due { flags = flags + 16; }
  if barrel_due { flags = flags + 32; }
  if barrel_due OR rocket_due { flags = flags + 64; }
}
return flags;
$doom$;

CREATE OR REPLACE FUNCTION doom_cs_monster_retarget(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
-- Targets. NULL means "the player" for a single-player world; in a
-- deathmatch the tic passes a different live player each time, so a monster
-- that is up and has no target takes the one it is handed and keeps it until
-- that player dies or leaves.
UPDATE monster_ai ai
SET target_thing_id = NULL
WHERE ai.map_id = p_map_id AND ai.target_thing_id IS NOT NULL
  AND (EXISTS (
    SELECT 1 FROM player_state ps
    WHERE ps.map_id = ai.map_id AND ps.player_thing_id = ai.target_thing_id
      AND (NOT ps.alive OR EXISTS (
        SELECT 1 FROM mp_players mp
        WHERE mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id
          AND mp.role_name IS NULL)))
    OR EXISTS (
    SELECT 1 FROM thing_health th
    WHERE th.map_id = ai.map_id AND th.thing_id = ai.target_thing_id AND NOT th.alive));

UPDATE monster_ai
SET target_thing_id = p_player_thing_id
WHERE map_id = p_map_id AND target_thing_id IS NULL AND state IN ('see', 'missile', 'pain');
$doom$;

-- noise alert
-- Firing wakes everything that can hear it. Doom floods the sound out from
-- the shooter's sector through P_RecursiveSound: it crosses a two-sided line
-- whose opening is not shut, and an ML_SOUNDBLOCK line absorbs one level, so
-- sound passes at most one of them before it stops.
CREATE OR REPLACE FUNCTION doom_cs_monster_noise(p_map_id integer)
LANGUAGE cedarscript AS $doom$
WITH RECURSIVE
noise_origin AS (
  SELECT ps.sector_id
  FROM player_state ps
  JOIN player_weapons pw ON pw.map_id = ps.map_id
   AND pw.player_thing_id = ps.player_thing_id
  WHERE ps.map_id = p_map_id::int
    AND ps.alive AND pw.fired_this_tick AND ps.sector_id IS NOT NULL
),
sound_edges AS (
  SELECT ld.fsec AS a, ld.bsec AS b,
         CASE WHEN (ld.flags & 64) <> 0 THEN 1 ELSE 0 END AS block
  FROM linedef_geom ld
  JOIN sectors sf ON sf.map_id = ld.map_id AND sf.id = ld.fsec
  JOIN sectors sb ON sb.map_id = ld.map_id AND sb.id = ld.bsec
  WHERE ld.map_id = p_map_id::int
    AND LEAST(sf.ceil_height, sb.ceil_height)
      - GREATEST(sf.floor_height, sb.floor_height) > 0
  UNION ALL
  SELECT ld.bsec, ld.fsec,
         CASE WHEN (ld.flags & 64) <> 0 THEN 1 ELSE 0 END
  FROM linedef_geom ld
  JOIN sectors sf ON sf.map_id = ld.map_id AND sf.id = ld.fsec
  JOIN sectors sb ON sb.map_id = ld.map_id AND sb.id = ld.bsec
  WHERE ld.map_id = p_map_id::int
    AND LEAST(sf.ceil_height, sb.ceil_height)
      - GREATEST(sf.floor_height, sb.floor_height) > 0
),
flood AS (
  SELECT sector_id, 0 AS block FROM noise_origin
  UNION
  SELECT e.b, f.block + e.block
  FROM flood f JOIN sound_edges e ON e.a = f.sector_id
  WHERE f.block + e.block <= 1
)
UPDATE monster_ai ai
SET state = 'see', seq_index = 0, state_tics = 0
FROM things t, render_things rt, flood fl
WHERE ai.map_id = p_map_id::int
  AND t.map_id = ai.map_id AND t.id = ai.thing_id
  AND rt.map_id = ai.map_id AND rt.thing_id = ai.thing_id
  AND ai.state = 'stand'
  AND NOT EXISTS (SELECT 1 FROM thing_combat_defs cd
                  WHERE cd.thing_type = t.type AND cd.explodes)
  AND COALESCE(ai.sector_id, rt.sector_id) = fl.sector_id;
$doom$;

-- Activation (line of sight and range) and one step of every monster's state
-- and frame animation. Unconditional: this is what decides the rest of the
-- plan, so it runs before doom_cs_monster_plan is asked for the other bits.
CREATE OR REPLACE FUNCTION doom_cs_monster_think(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let attack_range_default = doom_const('DEFAULT_ATTACK_RANGE');
let sight_range = doom_const('SIGHT_RANGE');
-- activation + state/frame advancement
WITH RECURSIVE
params AS (SELECT p_map_id::int AS map_id, p_player_thing_id::int AS player_thing_id),
player_pos AS (
  SELECT pp.px, pp.py
  FROM doom_player_pos pp JOIN params p ON pp.map_id = p.map_id
   AND pp.player_thing_id = p.player_thing_id
),
-- MF_SHADOW on the target, which for the player means the blur sphere.
shadow AS (
  SELECT sh.shadowed, sh.level_tics
  FROM doom_player_shadow sh JOIN params p ON sh.map_id = p.map_id
   AND sh.player_thing_id = p.player_thing_id
),
blocking_walls AS (
  SELECT ld.x1::double precision AS x1, ld.y1::double precision AS y1,
         ld.x2::double precision AS x2, ld.y2::double precision AS y2
  FROM linedef_geom ld
  JOIN params p ON ld.map_id = p.map_id
  LEFT JOIN sectors fr ON fr.map_id = ld.map_id AND fr.id = ld.fsec
  LEFT JOIN sectors bk ON bk.map_id = ld.map_id AND bk.id = ld.bsec
  -- Sight is blocked by one-sided walls and by live two-sided portals with no
  -- vertical opening.
  WHERE ld.left_sd_id = -1 OR ld.right_sd_id = -1
     OR fr.id IS NULL OR bk.id IS NULL
     OR LEAST(fr.ceil_height, bk.ceil_height)
          <= GREATEST(fr.floor_height, bk.floor_height)
),
monsters AS (
  SELECT ai.map_id, ai.thing_id, ai.state, ai.state_tics, ai.seq_index,
         ai.attack_cooldown, t.type, t.x::double precision AS mx,
         t.y::double precision AS my, t.angle::double precision AS facing,
         h.alive, h.health, h.max_health, cd.xdeath_frame,
         COALESCE(cd.explodes, FALSE) AS explodes,
         COALESCE(cd.attack_range, attack_range_default)::double precision AS attack_range
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
  JOIN thing_health h ON h.map_id = ai.map_id AND h.thing_id = ai.thing_id
  LEFT JOIN thing_combat_defs cd ON cd.thing_type = t.type
  WHERE h.alive OR ai.state <> 'dead'
),
mon_target AS (
  SELECT ai.thing_id,
         COALESCE(tt.x::double precision, pp.px) AS tx,
         COALESCE(tt.y::double precision, pp.py) AS ty
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  CROSS JOIN player_pos pp
  LEFT JOIN (SELECT map_id, thing_id FROM thing_health WHERE alive
             UNION ALL SELECT map_id, player_thing_id FROM player_state WHERE alive) th
    ON th.map_id = ai.map_id AND th.thing_id = ai.target_thing_id
  LEFT JOIN things tt ON tt.map_id = ai.map_id AND tt.id = th.thing_id
),
near_monsters AS (
  SELECT m.thing_id, m.mx, m.my, m.facing, mt.tx, mt.ty
  FROM monsters m
  JOIN mon_target mt ON mt.thing_id = m.thing_id
  WHERE power(m.mx - mt.tx, 2) + power(m.my - mt.ty, 2) <= sight_range * sight_range
),
near_los_walls AS (
  SELECT nm.thing_id,
         BOOL_OR((sides.d1 * sides.d2 < 0) AND (sides.d3 * sides.d4 < 0)) AS blocked
  FROM near_monsters nm
  JOIN blocking_walls b
    ON LEAST(b.x1, b.x2) <= GREATEST(nm.mx, nm.tx)
   AND GREATEST(b.x1, b.x2) >= LEAST(nm.mx, nm.tx)
   AND LEAST(b.y1, b.y2) <= GREATEST(nm.my, nm.ty)
   AND GREATEST(b.y1, b.y2) >= LEAST(nm.my, nm.ty)
  CROSS JOIN LATERAL (
    SELECT
      (nm.mx - b.x1) * (b.y2 - b.y1) - (nm.my - b.y1) * (b.x2 - b.x1) AS d1,
      (nm.tx - b.x1) * (b.y2 - b.y1) - (nm.ty - b.y1) * (b.x2 - b.x1) AS d2,
      (b.x1 - nm.mx) * (nm.ty - nm.my) - (b.y1 - nm.my) * (nm.tx - nm.mx) AS d3,
      (b.x2 - nm.mx) * (nm.ty - nm.my) - (b.y2 - nm.my) * (nm.tx - nm.mx) AS d4
  ) sides
  GROUP BY nm.thing_id
),
near_los AS (
  SELECT nm.thing_id,
    NOT COALESCE(w.blocked, FALSE) AS visible,
    (COS(RADIANS(nm.facing)) * (nm.tx - nm.mx)
     + SIN(RADIANS(nm.facing)) * (nm.ty - nm.my)) > 0 AS in_view_cone
  FROM near_monsters nm
  LEFT JOIN near_los_walls w ON w.thing_id = nm.thing_id
),
los AS (
  SELECT m.thing_id,
    COALESCE(nl.visible, FALSE) AS visible,
    COALESCE(nl.in_view_cone, FALSE) AS in_view_cone,
    sqrt(power(m.mx - mt.tx, 2) + power(m.my - mt.ty, 2)) AS dist
  FROM monsters m
  JOIN mon_target mt ON mt.thing_id = m.thing_id
  LEFT JOIN near_los nl ON nl.thing_id = m.thing_id
),
max_seq AS (
  SELECT thing_type, state, MAX(seq_index) AS max_idx
  FROM thing_ai_frames GROUP BY thing_type, state
),
decision AS (
  SELECT
    m.map_id, m.thing_id, m.state, m.state_tics, m.seq_index,
    m.attack_cooldown, m.type, m.alive, m.health, m.max_health,
    m.xdeath_frame, m.explodes, l.visible, l.in_view_cone, l.dist,
    m.attack_range,
    ms.max_idx AS see_max, mm.max_idx AS missile_max,
    mp.max_idx AS pain_max, md.max_idx AS die_max,
    mx.max_idx AS xdeath_max
  FROM monsters m
  JOIN los l ON l.thing_id = m.thing_id
  LEFT JOIN max_seq ms ON ms.thing_type = m.type AND ms.state = 'see'
  LEFT JOIN max_seq mm ON mm.thing_type = m.type AND mm.state = 'missile'
  LEFT JOIN max_seq mp ON mp.thing_type = m.type AND mp.state = 'pain'
  LEFT JOIN max_seq md ON md.thing_type = m.type AND md.state = 'die'
  LEFT JOIN max_seq mx ON mx.thing_type = m.type AND mx.state = 'xdeath'
),
transitions AS (
  SELECT d.*,
    d.state_tics <= 1
      OR (NOT d.alive AND d.state NOT IN ('die', 'dead', 'xdeath'))
      AS advances,
    CASE
      -- P_KillMobj: `health < -spawnhealth && xdeathstate` takes the extreme
      -- death rather than the ordinary one
      WHEN NOT d.alive AND d.state NOT IN ('die', 'dead', 'xdeath') THEN
        CASE WHEN d.health < -d.max_health AND d.xdeath_frame IS NOT NULL
             THEN 'xdeath'::actor_state ELSE 'die'::actor_state END
      WHEN d.state = 'die' THEN
        CASE WHEN d.state_tics > 1 THEN 'die'::actor_state
             WHEN d.seq_index >= d.die_max THEN 'dead'::actor_state
             ELSE 'die'::actor_state END
      WHEN d.state = 'xdeath' THEN
        CASE WHEN d.state_tics > 1 THEN 'xdeath'::actor_state
             WHEN d.seq_index >= d.xdeath_max THEN 'dead'::actor_state
             ELSE 'xdeath'::actor_state END
      -- Barrels use this same compact actor state table only for their death
      -- animation. While alive they never wake, chase, or attack.
      WHEN d.explodes THEN 'stand'::actor_state
      WHEN d.state = 'stand' THEN
        CASE WHEN d.visible AND d.in_view_cone AND d.dist <= sight_range
             THEN 'see'::actor_state ELSE 'stand'::actor_state END
      WHEN d.state_tics > 1 THEN d.state
      WHEN d.state = 'see' THEN
        CASE WHEN d.visible AND d.dist <= d.attack_range
                  AND d.attack_cooldown <= 0
             THEN 'missile'::actor_state ELSE 'see'::actor_state END
      WHEN d.state = 'missile' THEN
        CASE WHEN d.seq_index >= d.missile_max THEN 'see'::actor_state ELSE 'missile'::actor_state END
      WHEN d.state = 'pain' THEN
        CASE WHEN d.seq_index >= d.pain_max THEN 'see'::actor_state ELSE 'pain'::actor_state END
      ELSE d.state
    END AS next_state,
    CASE
      WHEN NOT d.alive AND d.state NOT IN ('die', 'dead', 'xdeath') THEN 0
      WHEN d.state = 'die' THEN
        CASE WHEN d.state_tics > 1 THEN d.seq_index
             WHEN d.seq_index >= d.die_max THEN 0
             ELSE d.seq_index + 1 END
      WHEN d.state = 'xdeath' THEN
        CASE WHEN d.state_tics > 1 THEN d.seq_index
             WHEN d.seq_index >= d.xdeath_max THEN 0
             ELSE d.seq_index + 1 END
      WHEN d.explodes THEN 0
      WHEN d.state = 'stand' THEN 0
      WHEN d.state_tics > 1 THEN d.seq_index
      WHEN d.state = 'see' THEN
        CASE WHEN d.visible AND d.dist <= d.attack_range
                  AND d.attack_cooldown <= 0
             THEN 0
             WHEN d.seq_index >= d.see_max THEN 0
             ELSE d.seq_index + 1 END
      WHEN d.state = 'missile' THEN
        CASE WHEN d.seq_index >= d.missile_max THEN 0 ELSE d.seq_index + 1 END
      WHEN d.state = 'pain' THEN
        CASE WHEN d.seq_index >= d.pain_max THEN 0 ELSE d.seq_index + 1 END
      ELSE d.seq_index
    END AS next_seq
  FROM decision d
),
next_values AS (
  SELECT t.map_id, t.thing_id, t.state AS old_state, t.next_state,
         t.next_seq, t.type, t.advances,
         CASE
           WHEN NOT t.advances THEN t.state_tics - 1
           WHEN t.next_state = 'stand' THEN -1
           -- G_InitNew's fast-monster loop halves the tics of every state
           -- from S_SARG_RUN1 to S_SARG_PAIN2 on Nightmare
           WHEN cd.fast_on_nightmare
                AND t.next_state IN ('see','missile','pain')
                AND (SELECT g.skill FROM game_tic_commands g
                     WHERE g.map_id=p_map_id::int
                       AND g.player_thing_id=p_player_thing_id::int)=4
             THEN GREATEST(1, COALESCE(f.tics, -1) >> 1)
           ELSE COALESCE(f.tics, -1)
         END AS next_tics,
         CASE WHEN t.state = 'missile' AND t.next_state = 'see' THEN 30
              ELSE GREATEST(0, t.attack_cooldown - 1) END AS next_cooldown,
         COALESCE(f.is_attack_frame, FALSE) AS lands_on_attack_frame
  FROM transitions t
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  LEFT JOIN thing_ai_frames f
    ON f.thing_type = t.type AND f.state = t.next_state
   AND f.seq_index = t.next_seq
)
UPDATE monster_ai ai
SET state = n.next_state, state_tics = n.next_tics,
    seq_index = n.next_seq, attack_cooldown = n.next_cooldown,
    fired_this_tick = n.advances AND n.lands_on_attack_frame
FROM next_values n
WHERE ai.map_id = n.map_id AND ai.thing_id = n.thing_id
  AND (ai.state <> n.next_state
    OR ai.state_tics <> n.next_tics
    OR ai.seq_index <> n.next_seq
    OR ai.attack_cooldown <> n.next_cooldown
    OR ai.fired_this_tick <> (n.advances AND n.lands_on_attack_frame));
$doom$;

-- Stage this tic's chase moves into monster_steps. Returns whether any
-- survived the wall and thing checks, which is the gate on doom_cs_monster_move.
CREATE OR REPLACE FUNCTION doom_cs_monster_step(p_map_id integer, p_player_thing_id integer) RETURNS boolean
LANGUAGE cedarscript AS $doom$
let blockmap_cell = doom_const('BLOCKMAP_CELL');
let min_walk_opening = doom_const('MIN_WALK_OPENING');
let max_step = doom_const('MAXSTEP');
let player_radius = doom_const('PLAYER_RADIUS');
let monster_step = doom_const('MONSTER_STEP');
let chase_deadband = doom_const('CHASE_AXIS_DEADBAND');
let chase_swap_chance = doom_const('CHASE_SWAP_CHANCE');
let chase_movecount_mask = doom_const('CHASE_MOVECOUNT_MASK');

WITH
params AS (SELECT p_map_id::int AS map_id, p_player_thing_id::int AS player_thing_id),
player_pos AS (
  SELECT pp.px, pp.py
  FROM doom_player_pos pp JOIN params p ON pp.map_id = p.map_id
   AND pp.player_thing_id = p.player_thing_id
),
-- MF_SHADOW on the target, which for the player means the blur sphere.
shadow AS (
  SELECT sh.shadowed, sh.level_tics
  FROM doom_player_shadow sh JOIN params p ON sh.map_id = p.map_id
   AND sh.player_thing_id = p.player_thing_id
),
chasers AS (
  SELECT ai.thing_id, t.x::double precision AS mx, t.y::double precision AS my,
         d.radius::double precision AS radius,
         d.floats, ai.movedir, ai.movecount
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type = t.type
  JOIN thing_ai_frames f ON f.thing_type=t.type AND f.state='see'
    AND f.seq_index=ai.seq_index
  WHERE ai.state='see' AND NOT d.explodes
    AND (ai.state_tics=f.tics
      OR ai.state_tics=FLOOR(f.tics/2.0)::int)
),
mon_target AS (
  SELECT ai.thing_id,
         COALESCE(tt.x::double precision, pp.px) AS tx,
         COALESCE(tt.y::double precision, pp.py) AS ty,
         ai.target_thing_id
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  CROSS JOIN player_pos pp
  LEFT JOIN (SELECT map_id, thing_id FROM thing_health WHERE alive
             UNION ALL SELECT map_id, player_thing_id FROM player_state WHERE alive) th
    ON th.map_id = ai.map_id AND th.thing_id = ai.target_thing_id
  LEFT JOIN things tt ON tt.map_id = ai.map_id AND tt.id = th.thing_id
),
walk AS (
  SELECT c.thing_id, c.mx, c.my, c.radius, c.floats, c.movedir, c.movecount,
         old.opposite AS turnaround,
         CASE WHEN mt.tx - c.mx >  chase_deadband THEN 0
              WHEN mt.tx - c.mx < -chase_deadband THEN 4 END AS dx_dir,
         CASE WHEN mt.ty - c.my < -chase_deadband THEN 6
              WHEN mt.ty - c.my >  chase_deadband THEN 2 END AS dy_dir,
         diag.dir AS diag,
         (doom_prandom(c.thing_id, sh.level_tics, 50) > chase_swap_chance
          OR ABS(mt.ty - c.my) > ABS(mt.tx - c.mx)) AS swap,
         (doom_prandom(c.thing_id, sh.level_tics, 51) & 1) = 1 AS sweep_up,
         (doom_prandom(c.thing_id, sh.level_tics, 52) & chase_movecount_mask::int)
           AS fresh_movecount,
         (c.movecount > 0 AND c.movedir IS NOT NULL) AS keep_going
  FROM chasers c
  JOIN mon_target mt ON mt.thing_id = c.thing_id
  CROSS JOIN shadow sh
  LEFT JOIN chase_dir_defs old ON old.dir = c.movedir
  JOIN chase_dir_defs diag ON diag.is_diagonal
   AND (diag.dx > 0) = (mt.tx - c.mx > 0)
   AND (diag.dy > 0) = (mt.ty - c.my >= 0)
),
-- P_NewChaseDir tries directions in a fixed order and takes the first that works.
ranked AS (
  SELECT w.thing_id, d.dir,
    LEAST(
      CASE WHEN w.keep_going AND d.dir = w.movedir THEN -1 ELSE 99 END,
      CASE WHEN w.dx_dir IS NOT NULL AND w.dy_dir IS NOT NULL AND d.dir = w.diag
            AND w.diag IS DISTINCT FROM w.turnaround THEN 0 ELSE 99 END,
      CASE WHEN d.dir = (CASE WHEN w.swap THEN w.dy_dir ELSE w.dx_dir END)
            AND d.dir IS DISTINCT FROM w.turnaround THEN 1 ELSE 99 END,
      CASE WHEN d.dir = (CASE WHEN w.swap THEN w.dx_dir ELSE w.dy_dir END)
            AND d.dir IS DISTINCT FROM w.turnaround THEN 2 ELSE 99 END,
      CASE WHEN d.dir = w.movedir THEN 3 ELSE 99 END,
      CASE WHEN d.dir IS DISTINCT FROM w.turnaround
           THEN 4 + CASE WHEN w.sweep_up THEN d.dir ELSE last.dir - d.dir END
           ELSE 99 END,
      CASE WHEN d.dir = w.turnaround THEN 12 ELSE 99 END
    ) AS pri
  FROM walk w CROSS JOIN chase_dir_defs d
  CROSS JOIN (SELECT MAX(dir) AS dir FROM chase_dir_defs) last
),
desired AS (
  SELECT r.pri, w.thing_id, w.mx, w.my, w.radius, w.floats,
         w.mx + monster_step * d.dx AS nx, w.my + monster_step * d.dy AS ny,
         d.angle AS face_angle, d.dir,
         CASE WHEN r.pri = -1 THEN w.movecount - 1
              ELSE w.fresh_movecount END AS next_movecount
  FROM ranked r
  JOIN walk w ON w.thing_id = r.thing_id
  JOIN chase_dir_defs d ON d.dir = r.dir
  WHERE r.pri < 99
),
blocking AS (
  SELECT ld.x1::double precision AS x1, ld.y1::double precision AS y1,
         ld.x2::double precision AS x2, ld.y2::double precision AS y2,
         -- blocked only by the 24-unit step rule: no wall for a floater
         (NOT (ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR (ld.flags & 1) <> 0)
          AND NOT (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL
                   AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
                   AND (LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height)) < min_walk_opening))
           AS floor_step_only
  FROM linedef_geom ld
  JOIN params p ON ld.map_id = p.map_id
  LEFT JOIN sectors sf ON sf.map_id = ld.map_id AND sf.id = ld.fsec
  LEFT JOIN sectors sb ON sb.map_id = ld.map_id AND sb.id = ld.bsec
  WHERE ld.left_sd_id = -1 OR ld.right_sd_id = -1
     OR (ld.flags & 1) <> 0
     OR (sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
         AND ABS(sb.floor_height - sf.floor_height) > max_step)
     OR (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL
         AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
         AND (LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height)) < min_walk_opening)
),
-- PIT_CheckThing for monsters. Everything solid blocks everything else, so a
-- monster is stopped by another monster, by a barrel, by a solid decoration
-- and by the player
solid_things AS (
  SELECT tt.id AS thing_id, tt.x::double precision AS tx,
         tt.y::double precision AS ty, cd.radius::double precision AS radius,
         FLOOR(tt.x / blockmap_cell)::int AS cellx,
         FLOOR(tt.y / blockmap_cell)::int AS celly
  FROM things tt
  JOIN params p ON tt.map_id = p.map_id
  JOIN thing_combat_defs cd ON cd.thing_type = tt.type
  JOIN thing_health hh ON hh.map_id = tt.map_id AND hh.thing_id = tt.id
   AND hh.alive
  UNION ALL
  -- Solid decorations
  SELECT tt.id, tt.x::double precision, tt.y::double precision,
         bd.radius::double precision,
         FLOOR(tt.x / blockmap_cell)::int, FLOOR(tt.y / blockmap_cell)::int
  FROM things tt
  JOIN params p ON tt.map_id = p.map_id
  JOIN thing_blocking_defs bd ON bd.thing_type = tt.type
  JOIN game_tic_commands g ON g.map_id = tt.map_id
   AND g.player_thing_id = p.player_thing_id
  WHERE (tt.flags & g.skill_bit) <> 0 AND (tt.flags & 16) = 0
  UNION ALL
  -- Every live player
  SELECT ps.player_thing_id, t.x::double precision, t.y::double precision, player_radius,
         FLOOR(t.x / blockmap_cell)::int, FLOOR(t.y / blockmap_cell)::int
  FROM player_state ps
  JOIN params p ON ps.map_id = p.map_id
  JOIN things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
  WHERE ps.alive
),
candidates AS (
  SELECT d.pri, d.thing_id, d.nx AS cx, d.ny AS cy,
         d.mx AS old_x, d.my AS old_y, d.radius, d.face_angle, d.floats,
         d.dir, d.next_movecount
  FROM desired d
),
thing_hit AS (
  SELECT c.pri, c.thing_id, TRUE AS hit
  FROM candidates c
  -- The 3x3 block of cells around the candidate: the largest radius sum in
  -- play is well under a cell, so a neighbour cell is as far as an overlap
  -- can reach.
  CROSS JOIN (SELECT generate_series(-1,1) AS d) gx
  CROSS JOIN (SELECT generate_series(-1,1) AS d) gy
  JOIN solid_things st
    ON st.cellx = FLOOR(c.cx / blockmap_cell)::int + gx.d
   AND st.celly = FLOOR(c.cy / blockmap_cell)::int + gy.d
   AND st.thing_id <> c.thing_id
   AND ABS(st.tx - c.cx) < st.radius + c.radius
   AND ABS(st.ty - c.cy) < st.radius + c.radius
  GROUP BY c.pri, c.thing_id
),
wall_block AS (
  -- Candidates against the walls whose box overlaps the step, aggregated to
  -- one verdict per candidate.
  SELECT c.pri, c.thing_id,
         BOOL_OR(dd.dist < c.radius OR xing.intersects) AS blocked
  FROM candidates c
  JOIN blocking b
    ON NOT (b.floor_step_only AND c.floats)
   AND LEAST(b.x1, b.x2) <= GREATEST(c.cx, c.old_x) + c.radius + 2.0
   AND GREATEST(b.x1, b.x2) >= LEAST(c.cx, c.old_x) - c.radius - 2.0
   AND LEAST(b.y1, b.y2) <= GREATEST(c.cy, c.old_y) + c.radius + 2.0
   AND GREATEST(b.y1, b.y2) >= LEAST(c.cy, c.old_y) - c.radius - 2.0
  CROSS JOIN LATERAL (
    SELECT LEAST(1.0, GREATEST(0.0,
      ((c.cx - b.x1) * (b.x2 - b.x1) + (c.cy - b.y1) * (b.y2 - b.y1))
      / NULLIF((b.x2 - b.x1) * (b.x2 - b.x1) + (b.y2 - b.y1) * (b.y2 - b.y1), 0.0)
    )) AS t
  ) lt
  CROSS JOIN LATERAL (
    SELECT sqrt((c.cx - (b.x1 + lt.t * (b.x2 - b.x1)))^2 + (c.cy - (b.y1 + lt.t * (b.y2 - b.y1)))^2) AS dist
  ) dd
  CROSS JOIN LATERAL (
    SELECT
      (c.old_x - b.x1) * (b.y2 - b.y1) - (c.old_y - b.y1) * (b.x2 - b.x1) AS d1,
      (c.cx - b.x1) * (b.y2 - b.y1) - (c.cy - b.y1) * (b.x2 - b.x1) AS d2,
      (b.x1 - c.old_x) * (c.cy - c.old_y) - (b.y1 - c.old_y) * (c.cx - c.old_x) AS d3,
      (b.x2 - c.old_x) * (c.cy - c.old_y) - (b.y2 - c.old_y) * (c.cx - c.old_x) AS d4
  ) sides
  CROSS JOIN LATERAL (
    SELECT ((sides.d1 * sides.d2 < 0) AND (sides.d3 * sides.d4 < 0)) AS intersects
  ) xing
  GROUP BY c.pri, c.thing_id
),
candidate_blocked AS (
  SELECT c.pri, c.thing_id, c.cx, c.cy, c.old_x, c.old_y, c.face_angle,
         c.dir, c.next_movecount,
         COALESCE(wb.blocked, FALSE) OR COALESCE(th2.hit, FALSE) AS blocked
  FROM candidates c
  LEFT JOIN wall_block wb ON wb.pri = c.pri AND wb.thing_id = c.thing_id
  LEFT JOIN thing_hit th2 ON th2.pri = c.pri AND th2.thing_id = c.thing_id
),
best_pos AS (
  SELECT thing_id, cx, cy, old_x, old_y, face_angle, dir, next_movecount FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY thing_id ORDER BY pri) AS rn
    FROM candidate_blocked WHERE NOT blocked
  ) r WHERE rn = 1
),
stuck AS (
  SELECT w.thing_id, w.mx, w.my, w.fresh_movecount
  FROM walk w
  WHERE NOT EXISTS (SELECT 1 FROM best_pos bp WHERE bp.thing_id = w.thing_id)
)
INSERT INTO monster_steps
  (map_id,thing_id,old_x,old_y,new_x,new_y,face_angle,movedir,movecount)
SELECT p_map_id::int, bp.thing_id, bp.old_x, bp.old_y, bp.cx, bp.cy,
       bp.face_angle, bp.dir, GREATEST(0, bp.next_movecount)
FROM best_pos bp
UNION ALL
SELECT p_map_id::int, s.thing_id, s.mx, s.my, s.mx, s.my, 0, NULL, s.fresh_movecount
FROM stuck s;

-- A_Chase's bookkeeping
UPDATE monster_ai ai
SET movedir = ms.movedir, movecount = ms.movecount
FROM monster_steps ms
WHERE ai.map_id = p_map_id AND ms.map_id = p_map_id
  AND ai.thing_id = ms.thing_id
  AND (ai.movedir IS DISTINCT FROM ms.movedir OR ai.movecount <> ms.movecount);
let mut stepped = false;
SELECT EXISTS (SELECT 1 FROM monster_steps
               WHERE map_id=p_map_id
                 AND (new_x <> old_x OR new_y <> old_y)) AS e
  { stepped = e; }
return stepped;
$doom$;

-- Apply the staged poses, then the lines those moves crossed and the
-- teleports they landed on.
CREATE OR REPLACE FUNCTION doom_cs_monster_move(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
-- apply the staged pose
UPDATE things t
SET x = ms.new_x, y = ms.new_y, angle = ms.face_angle
FROM monster_steps ms
WHERE ms.map_id = p_map_id AND t.map_id = p_map_id AND t.id = ms.thing_id
  AND (ms.new_x <> ms.old_x OR ms.new_y <> ms.old_y);

-- monster-crossable walk-over lines
--  a monster trips only the teleports, the down-wait-up lifts and the plain raise-door, and nothing else.
INSERT INTO line_special_events
  (map_id,player_thing_id,line_id,trigger_type,from_front)
SELECT e.map_id,e.thing_id,e.line_id,'cross',e.from_front
FROM (
  SELECT c.map_id, c.thing_id, c.line_id, c.from_front
  FROM (
    SELECT ms.map_id, ms.thing_id, ld.id AS line_id, ld.cross_once,
      ((v2.x-v1.x)::float8*(ms.old_y-v1.y)::float8
        - (v2.y-v1.y)::float8*(ms.old_x-v1.x)::float8) < 0 AS from_front,
      ABS((v2.x-v1.x)::float8*(ms.old_y-v1.y)::float8
        - (v2.y-v1.y)::float8*(ms.old_x-v1.x)::float8) AS old_side,
      ((v2.x-v1.x)::float8*(ms.new_y-v1.y)::float8
        - (v2.y-v1.y)::float8*(ms.new_x-v1.x)::float8) AS new_side,
      ((ms.new_x-ms.old_x)*(v1.y-ms.old_y)::float8
        - (ms.new_y-ms.old_y)*(v1.x-ms.old_x)::float8) AS v1_side,
      ((ms.new_x-ms.old_x)*(v2.y-ms.old_y)::float8
        - (ms.new_y-ms.old_y)*(v2.x-ms.old_x)::float8) AS v2_side
    FROM monster_steps ms
    JOIN linedefs ld ON ld.map_id = ms.map_id AND ld.monster_crossable
    JOIN vertexes v1 ON v1.map_id=ld.map_id AND v1.id=ld.v1_id
    JOIN vertexes v2 ON v2.map_id=ld.map_id AND v2.id=ld.v2_id
    WHERE ms.map_id = p_map_id
      AND (ms.new_x <> ms.old_x OR ms.new_y <> ms.old_y)
  ) c
  WHERE c.old_side > 1e-7
    AND c.new_side <> 0
    AND ((c.from_front AND c.new_side > 0)
      OR (NOT c.from_front AND c.new_side < 0))
    AND c.v1_side * c.v2_side < 0
    AND NOT (c.cross_once AND EXISTS (
      SELECT 1 FROM line_activations a
      WHERE a.map_id = c.map_id AND a.line_id = c.line_id))
) e
ON CONFLICT (map_id,player_thing_id,line_id,trigger_type) DO NOTHING;

-- EV_Teleport for a monster
DELETE FROM monster_teleports WHERE map_id=p_map_id;

INSERT INTO monster_teleports (map_id,thing_id,dest_x,dest_y,dest_angle,sector_id)
SELECT map_id,thing_id,dest_x,dest_y,dest_angle,sector_id FROM (
  SELECT c.*, ROW_NUMBER() OVER
    (PARTITION BY c.map_id,c.thing_id ORDER BY c.off_centre, c.dest_id) AS rn
  FROM (
    SELECT t.map_id, t.thing_id, t.sector_id,
           th.id AS dest_id, th.x AS dest_x, th.y AS dest_y,
           th.angle AS dest_angle,
           ABS(th.x - (t.min_x+t.max_x)/2.0)
             + ABS(th.y - (t.min_y+t.max_y)/2.0) AS off_centre
    FROM (
      SELECT e.map_id, e.player_thing_id AS thing_id, s.id AS sector_id,
             MIN(rs.x1) AS min_x, MAX(rs.x1) AS max_x,
             MIN(rs.y1) AS min_y, MAX(rs.y1) AS max_y
      FROM line_special_events e
      JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
      JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='teleport'
      -- Monster-owned events only: the player's id is never in monster_ai.
      JOIN monster_ai ai ON ai.map_id=e.map_id AND ai.thing_id=e.player_thing_id
      JOIN sectors s ON s.map_id=e.map_id AND s.tag=ld.tag
      JOIN render_segs rs ON rs.map_id=s.map_id AND rs.fsec=s.id
      WHERE e.map_id=p_map_id AND e.trigger_type='cross'
      GROUP BY e.map_id, e.player_thing_id, s.id
    ) t
    JOIN things th ON th.map_id=t.map_id
    JOIN thing_role_defs tr ON tr.thing_type=th.type AND tr.is_teleport_dest
     AND th.x BETWEEN t.min_x AND t.max_x
     AND th.y BETWEEN t.min_y AND t.max_y
  ) c
) q WHERE rn=1;

-- sfx_telept at the spot left behind and at the one arrived at, as
-- EV_Teleport's two MT_TFOGs do. The fog sprite itself is not modelled.
INSERT INTO sound_events
  (map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y)
SELECT mt.map_id,'mon-tele-out:'||mt.thing_id::text||':'||ps.level_tics::text,
       ps.level_tics,'DSTELEPT',mt.thing_id,ms.old_x,ms.old_y
FROM monster_teleports mt
JOIN monster_steps ms ON ms.map_id=mt.map_id AND ms.thing_id=mt.thing_id
JOIN player_state ps ON ps.map_id=mt.map_id
 AND ps.player_thing_id=p_player_thing_id::int
WHERE mt.map_id=p_map_id
UNION ALL
SELECT mt.map_id,'mon-tele-in:'||mt.thing_id::text||':'||ps.level_tics::text,
       ps.level_tics,'DSTELEPT',mt.thing_id,mt.dest_x,mt.dest_y
FROM monster_teleports mt
JOIN player_state ps ON ps.map_id=mt.map_id
 AND ps.player_thing_id=p_player_thing_id::int
WHERE mt.map_id=p_map_id
ON CONFLICT (map_id,event_key) DO NOTHING;

UPDATE things t
SET x=mt.dest_x, y=mt.dest_y, angle=mt.dest_angle
FROM monster_teleports mt
WHERE t.map_id=p_map_id AND mt.map_id=p_map_id AND t.id=mt.thing_id;

UPDATE monster_ai ai
SET sector_id=mt.sector_id
FROM monster_teleports mt
WHERE ai.map_id=p_map_id AND mt.map_id=p_map_id AND ai.thing_id=mt.thing_id
  AND ai.sector_id IS DISTINCT FROM mt.sector_id;
$doom$;

CREATE OR REPLACE FUNCTION doom_cs_monster_float(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let view_height = doom_const('VIEWHEIGHT');
let player_height = doom_const('PLAYER_HEIGHT');
let skull_speed = doom_const('SKULL_CHARGE_SPEED');
let skull_reach = doom_const('SKULL_HIT_REACH');
let ticrate = doom_const('TICRATE');
-- P_ZMovement's float
-- A floater drifts 4 units a tic toward its target's mid-height once it is
-- close enough horizontally (within three times the height difference), and
-- stays between its sector's floor and the ceiling minus its own height.
UPDATE things t
SET z = LEAST(q.ceil_height - q.height, GREATEST(q.floor_height,
          t.z + CASE WHEN q.delta > 0 AND q.dist < q.delta * 3 THEN 4
                     WHEN q.delta < 0 AND q.dist < -q.delta * 3 THEN -4 ELSE 0 END))::real
FROM (
  SELECT ai.thing_id, s.floor_height, s.ceil_height, d.height,
         ((ps.base_z - view_height) + player_height/2.0) - th.z AS delta,
         SQRT(POWER(pt.x - th.x, 2) + POWER(pt.y - th.y, 2)) AS dist
  FROM monster_ai ai
  JOIN things th ON th.map_id = ai.map_id AND th.id = ai.thing_id
  LEFT JOIN render_things rt ON rt.map_id = ai.map_id AND rt.thing_id = ai.thing_id
  JOIN sectors s ON s.map_id = ai.map_id AND s.id = COALESCE(ai.sector_id, rt.sector_id)
  JOIN player_state ps ON ps.map_id = ai.map_id
   AND ps.player_thing_id = COALESCE(ai.target_thing_id, p_player_thing_id::int)
  JOIN things pt ON pt.map_id = ps.map_id AND pt.id = ps.player_thing_id
  JOIN thing_combat_defs d ON d.thing_type = th.type
  WHERE ai.map_id = p_map_id AND d.floats AND ai.state IN ('see','missile')
) q
WHERE t.map_id = p_map_id AND t.id = q.thing_id;

-- A_SkullAttack
-- The lost soul's attack frame hurls it at its target at 20 units a tic;
-- doom_cs_thing_physics carries the momentum and stops it at walls, and the
-- charge is over when it lands (below), hits a wall, or runs out.
UPDATE things t
SET mom_x = (skull_speed * (q.tx - t.x) / q.len)::real,
    mom_y = (skull_speed * (q.ty - t.y) / q.len)::real
FROM (
  SELECT ai.thing_id, pt.x::float8 AS tx, pt.y::float8 AS ty,
         SQRT(POWER(pt.x - th.x, 2) + POWER(pt.y - th.y, 2)) AS len
  FROM monster_ai ai
  JOIN things th ON th.map_id = ai.map_id AND th.id = ai.thing_id
  JOIN things pt ON pt.map_id = ai.map_id
   AND pt.id = COALESCE(ai.target_thing_id, p_player_thing_id::int)
  JOIN thing_combat_defs d ON d.thing_type = th.type AND d.skull_fly
  WHERE ai.map_id = p_map_id AND ai.fired_this_tick
) q
WHERE t.map_id = p_map_id AND t.id = q.thing_id AND q.len > 0;

UPDATE monster_ai ai
SET charge_tics = CASE WHEN ai.fired_this_tick THEN ticrate ELSE GREATEST(0, ai.charge_tics - 1) END
FROM things t JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
WHERE ai.map_id = p_map_id AND t.map_id = ai.map_id AND t.id = ai.thing_id
  AND (ai.fired_this_tick OR ai.charge_tics > 0);

-- The charge lands: 3d8 to a player within reach, and the skull stops.
UPDATE player_state ps
SET armor = ps.armor - d.saved,
    armor_class = CASE WHEN ps.armor - d.saved <= 0 THEN 0 ELSE ps.armor_class END,
    health = GREATEST(0, ps.health - (d.dmg - d.saved)),
    damage_count = LEAST(100, ps.damage_count + (d.dmg - d.saved)),
    pain_face_tics = 12,
    alive = (ps.health - (d.dmg - d.saved)) > 0,
    killer_id = CASE WHEN (ps.health - (d.dmg - d.saved)) <= 0 THEN -1 ELSE ps.killer_id END
FROM (
  SELECT ps2.map_id, ps2.player_thing_id, q.dmg,
         LEAST(ps2.armor, CASE ps2.armor_class WHEN 2 THEN q.dmg / 2 WHEN 1 THEN q.dmg / 3 ELSE 0 END) AS saved
  FROM player_state ps2
  JOIN (
    SELECT ps3.player_thing_id,
           SUM((doom_prandom(t.id, ps3.level_tics, 21) % d.charge_sides + 1)
               * d.charge_mult)::int AS dmg
    FROM monster_ai ai
    JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
    JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
    JOIN player_state ps3 ON ps3.map_id = ai.map_id AND ps3.alive
    JOIN things pt ON pt.map_id = ps3.map_id AND pt.id = ps3.player_thing_id
    WHERE ai.map_id = p_map_id AND ai.charge_tics > 0
      AND ABS(pt.x - t.x) < skull_reach AND ABS(pt.y - t.y) < skull_reach
    GROUP BY ps3.player_thing_id
  ) q ON q.player_thing_id = ps2.player_thing_id
  WHERE ps2.map_id = p_map_id AND NOT ps2.god_mode AND ps2.invuln_tics <= 0
) d
WHERE ps.map_id = d.map_id AND ps.player_thing_id = d.player_thing_id;

UPDATE things t
SET mom_x = 0, mom_y = 0
FROM monster_ai ai JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
WHERE t.map_id = p_map_id AND ai.map_id = t.map_id AND ai.thing_id = t.id
  AND ai.charge_tics > 0
  AND EXISTS (SELECT 1 FROM player_state ps JOIN things pt ON pt.map_id = ps.map_id AND pt.id = ps.player_thing_id
              WHERE ps.map_id = t.map_id AND ABS(pt.x - t.x) < skull_reach AND ABS(pt.y - t.y) < skull_reach);

UPDATE monster_ai ai
SET charge_tics = 0
FROM things t JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
WHERE ai.map_id = p_map_id AND t.map_id = ai.map_id AND t.id = ai.thing_id
  AND ai.charge_tics > 0 AND t.mom_x = 0 AND t.mom_y = 0 AND NOT ai.fired_this_tick;
$doom$;

CREATE OR REPLACE FUNCTION doom_cs_monster_chase(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
-- a blocked monster opens the door
-- P_Move, when its step fails, retries the lines it hit as use-specials, and
-- P_UseSpecialLine lets a monster through exactly four door types (1, 32, 33,
-- 34 -- key doors included, since the key check is skipped for anything that
-- is not a player). ML_SECRET lines are never opened.
INSERT INTO line_special_events
  (map_id,player_thing_id,line_id,trigger_type,from_front)
SELECT DISTINCT p_map_id::int, ai.thing_id, ld.linedef_id, 'use', TRUE
FROM monster_ai ai
JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
JOIN thing_combat_defs cd ON cd.thing_type = t.type
JOIN things pt ON pt.map_id = ai.map_id AND pt.id = p_player_thing_id::int
JOIN linedef_geom ld ON ld.map_id = ai.map_id
JOIN line_special_defs d ON d.special = ld.special AND d.monster_usable
CROSS JOIN LATERAL (
  SELECT SQRT(POWER(pt.x - t.x, 2) + POWER(pt.y - t.y, 2))::double precision AS dist
) toward
CROSS JOIN LATERAL (
  SELECT t.x + 8.0 * (pt.x - t.x) / NULLIF(toward.dist, 0) AS sx,
         t.y + 8.0 * (pt.y - t.y) / NULLIF(toward.dist, 0) AS sy
) step
CROSS JOIN LATERAL (
  SELECT LEAST(1.0, GREATEST(0.0,
    ((step.sx - ld.x1) * (ld.x2 - ld.x1) + (step.sy - ld.y1) * (ld.y2 - ld.y1))
    / NULLIF(POWER(ld.x2 - ld.x1, 2) + POWER(ld.y2 - ld.y1, 2), 0.0))) AS u
) proj
CROSS JOIN LATERAL (
  SELECT SQRT(POWER(step.sx - (ld.x1 + proj.u * (ld.x2 - ld.x1)), 2)
            + POWER(step.sy - (ld.y1 + proj.u * (ld.y2 - ld.y1)), 2)) AS gap
) near
LEFT JOIN sidedefs back ON back.map_id = ld.map_id AND back.id = ld.left_sd_id
LEFT JOIN sector_movers sm ON sm.map_id = ld.map_id
  AND sm.sector_id = back.sector_id AND sm.direction <> -1
WHERE ai.map_id = p_map_id::int
  AND ai.state = 'see'
  AND NOT cd.explodes
  AND (ld.flags & 32) = 0
  AND near.gap < cd.radius
  AND sm.sector_id IS NULL
ON CONFLICT (map_id,player_thing_id,line_id,trigger_type) DO NOTHING;

-- live sector for monsters now in 'see'
WITH RECURSIVE
params AS (SELECT p_map_id::int AS map_id),
movers AS (
  -- A monster's sector can only change on a tic it stepped, so only those
  -- descend the BSP again -- plus any chaser that has never been placed.
  -- Descending for every chaser was ~3/4 of this statement.
  SELECT ai.thing_id, t.x::double precision AS mx, t.y::double precision AS my
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
  WHERE ai.state = 'see'
    AND (ai.sector_id IS NULL
         OR EXISTS (SELECT 1 FROM monster_steps ms
                    WHERE ms.map_id = ai.map_id AND ms.thing_id = ai.thing_id))
),
bsp AS (
  SELECT m.thing_id, 1 AS depth, n.id AS node_id, NULL::int AS ssec_id
  FROM movers m
  CROSS JOIN LATERAL (
    SELECT n.id FROM nodes n JOIN params p ON n.map_id = p.map_id
    ORDER BY n.id DESC LIMIT 1
  ) n
  UNION ALL
  SELECT w.thing_id, w.depth + 1,
    CASE WHEN nc.child_kind = 'NODE' THEN nc.child_node_id END,
    CASE WHEN nc.child_kind = 'SSECTOR' THEN nc.child_ssector_id END
  FROM bsp w
  JOIN params p ON TRUE
  JOIN movers m ON m.thing_id = w.thing_id
  JOIN nodes n ON n.map_id = p.map_id AND n.id = w.node_id
  JOIN node_children nc ON nc.map_id = p.map_id AND nc.node_id = n.id
    AND nc.side = CASE
      WHEN (m.mx - n.x)::float8 * n.dy::float8
           - (m.my - n.y)::float8 * n.dx::float8 > 0
      THEN 'R' ELSE 'L' END
  WHERE w.node_id IS NOT NULL
),
subsector AS (
  SELECT thing_id, ssec_id FROM (
    SELECT thing_id, ssec_id, ROW_NUMBER() OVER
      (PARTITION BY thing_id ORDER BY depth, ssec_id) AS rn
    FROM bsp WHERE ssec_id IS NOT NULL
  ) r WHERE rn = 1
),
sector_of AS (
  SELECT ss.thing_id, s.id AS sector_id,
    ROW_NUMBER() OVER (PARTITION BY ss.thing_id ORDER BY seg.id) AS rn
  FROM subsector ss
  JOIN params p ON TRUE
  JOIN ssectors sst ON sst.map_id = p.map_id AND sst.id = ss.ssec_id
  JOIN segs seg ON seg.map_id = p.map_id
    AND seg.id >= sst.first_seg_id AND seg.id < sst.first_seg_id + sst.seg_count
  JOIN linedefs ld ON ld.map_id = p.map_id AND ld.id = seg.linedef_id
  JOIN sidedefs sd ON sd.map_id = p.map_id
    AND sd.id = CASE WHEN seg.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
  JOIN sectors s ON s.map_id = p.map_id AND s.id = sd.sector_id
)
UPDATE monster_ai ai
SET sector_id = so.sector_id
FROM sector_of so
WHERE so.rn = 1 AND ai.map_id = p_map_id AND ai.thing_id = so.thing_id
  -- A monster that did not move is still in the sector it was in
  AND ai.sector_id IS DISTINCT FROM so.sector_id;

-- keep the render cache's sector in step
UPDATE render_things rt
SET sector_id = ai.sector_id
FROM monster_ai ai
WHERE rt.map_id = p_map_id AND ai.map_id = p_map_id
  AND ai.thing_id = rt.thing_id
  AND ai.sector_id IS NOT NULL
  AND rt.sector_id <> ai.sector_id;
$doom$;

CREATE OR REPLACE FUNCTION doom_cs_monster_attack(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let attack_range_default = doom_const('DEFAULT_ATTACK_RANGE');
let hitscan_spread = doom_const('HITSCAN_SPREAD_UNITS');
let shadow_miss = doom_const('SHADOW_MISS_UNITS');
let melee_reach = doom_const('MELEE_REACH');
let player_radius = doom_const('PLAYER_RADIUS');

DELETE FROM monster_attack_damage WHERE map_id = p_map_id;
WITH
params AS (SELECT p_map_id::int AS map_id, p_player_thing_id::int AS player_thing_id),
player_pos AS (
  SELECT pp.px, pp.py
  FROM doom_player_pos pp JOIN params p ON pp.map_id = p.map_id
   AND pp.player_thing_id = p.player_thing_id
),
-- Every live player on the map. A monster attacks the one it is angry with
-- (mon_target below); a barrel's blast reaches all of them.
players AS (
  SELECT ps.player_thing_id, t.x::double precision AS px, t.y::double precision AS py
  FROM player_state ps JOIN params p ON ps.map_id = p.map_id
  JOIN things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
  WHERE ps.alive
),
targets AS (
  SELECT player_thing_id, px, py FROM players
  UNION ALL
  SELECT p.player_thing_id, pp.px, pp.py
  FROM params p CROSS JOIN player_pos pp
  WHERE NOT EXISTS (SELECT 1 FROM players q
                    WHERE q.player_thing_id = p.player_thing_id)
),
-- MF_SHADOW on the target, which for the player means the blur sphere.
shadow AS (
  SELECT sh.shadowed, sh.level_tics
  FROM doom_player_shadow sh JOIN params p ON sh.map_id = p.map_id
   AND sh.player_thing_id = p.player_thing_id
),
attackers AS (
  SELECT a.thing_id, a.type, a.mx, a.my,
         a.hitscan_pellets, a.hitscan_mult, a.hitscan_sides,
         a.melee_mult, a.melee_sides, a.explodes,
         a.blast_radius
  FROM doom_monster_attackers a JOIN params p ON a.map_id = p.map_id
),
blocking_walls AS (
  SELECT ld.x1::double precision AS x1, ld.y1::double precision AS y1,
         ld.x2::double precision AS x2, ld.y2::double precision AS y2
  FROM linedef_geom ld JOIN params p ON ld.map_id = p.map_id
  LEFT JOIN sectors fr ON fr.map_id = ld.map_id AND fr.id = ld.fsec
  LEFT JOIN sectors bk ON bk.map_id = ld.map_id AND bk.id = ld.bsec
  -- Recheck live portal geometry on the attack frame. This prevents a shot
  -- already being animated from damaging the player after its door closes.
  WHERE ld.left_sd_id = -1 OR ld.right_sd_id = -1
     OR fr.id IS NULL OR bk.id IS NULL
     OR LEAST(fr.ceil_height, bk.ceil_height)
          <= GREATEST(fr.floor_height, bk.floor_height)
),
mon_target AS (
  SELECT ai.thing_id,
         COALESCE(tt.x::double precision, pp.px) AS tx,
         COALESCE(tt.y::double precision, pp.py) AS ty,
         CASE WHEN th.thing_id IS NULL THEN NULL ELSE ai.target_thing_id END
           AS victim_id,
         COALESCE(tp.player_thing_id, pp.player_thing_id) AS victim_player
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  JOIN things at ON at.map_id = ai.map_id AND at.id = ai.thing_id
  JOIN thing_combat_defs acd ON acd.thing_type = at.type
  JOIN targets pp ON (acd.explodes OR pp.player_thing_id = p.player_thing_id)
  LEFT JOIN things tt ON tt.map_id = ai.map_id AND tt.id = ai.target_thing_id
  LEFT JOIN thing_health th ON th.map_id = ai.map_id
   AND th.thing_id = ai.target_thing_id AND th.alive
  LEFT JOIN player_state tp ON tp.map_id = ai.map_id
   AND tp.player_thing_id = ai.target_thing_id AND tp.alive
),
hits AS (
  SELECT a.thing_id, a.type, a.hitscan_pellets, a.hitscan_mult, a.hitscan_sides,
    a.melee_mult, a.melee_sides, a.explodes,
    a.blast_radius,
    mt.victim_id, mt.victim_player, sh.level_tics AS tic,
    sqrt(power(a.mx - pp.px, 2) + power(a.my - pp.py, 2)) AS dist,
    NOT EXISTS (
      SELECT 1 FROM blocking_walls b
      CROSS JOIN LATERAL (
        SELECT
          (a.mx - b.x1) * (b.y2 - b.y1) - (a.my - b.y1) * (b.x2 - b.x1) AS d1,
          (pp.px - b.x1) * (b.y2 - b.y1) - (pp.py - b.y1) * (b.x2 - b.x1) AS d2,
          (b.x1 - a.mx) * (pp.py - a.my) - (b.y1 - a.my) * (pp.px - a.mx) AS d3,
          (b.x2 - a.mx) * (pp.py - a.my) - (b.y2 - a.my) * (pp.px - a.mx) AS d4
      ) sides
      WHERE (sides.d1 * sides.d2 < 0) AND (sides.d3 * sides.d4 < 0)
    ) AS visible
  FROM attackers a
  CROSS JOIN shadow sh
  JOIN mon_target mt ON mt.thing_id = a.thing_id
  CROSS JOIN LATERAL (SELECT mt.tx AS px, mt.ty AS py) pp
),
pellet_random AS (
  SELECT h.thing_id,h.type,h.victim_id,h.victim_player,h.dist,h.visible,g.pellet,
         doom_prandom(h.thing_id, h.tic * 8 + g.pellet, 12) AS r1,
         doom_prandom(h.thing_id, h.tic * 8 + g.pellet, 13) AS r2,
         (doom_prandom(h.thing_id, h.tic * 8 + g.pellet, 14)
            % h.hitscan_sides + 1) * h.hitscan_mult
           AS pellet_damage,

         CASE WHEN sh.shadowed
              THEN (doom_prandom(h.thing_id, h.tic, 15)
                   -doom_prandom(h.thing_id, h.tic, 16))*360.0/shadow_miss
              ELSE 0.0 END AS shadow_err
  FROM hits h
  CROSS JOIN shadow sh
  CROSS JOIN LATERAL generate_series(1, h.hitscan_pellets) g(pellet)
  WHERE h.hitscan_pellets IS NOT NULL
),
damage AS (
  SELECT thing_id, victim_id, victim_player,
    CASE WHEN visible AND dist<=attack_range_default
           AND (dist<=player_radius OR
             ABS((r1-r2)*360.0/hitscan_spread + shadow_err)
               <=DEGREES(ASIN(LEAST(1.0,player_radius/NULLIF(dist,0.0)))))
         THEN pellet_damage ELSE 0 END AS dmg
  FROM pellet_random
  UNION ALL
  SELECT thing_id, victim_id, victim_player,
    CASE
      -- The bite at MELEERANGE (A_TroopAttack, A_SargAttack, A_HeadAttack,
      -- A_BruisAttack): melee_mult * (1..melee_sides) from the catalogue. A
      -- line attack, so the thing has to see its target.
      WHEN melee_mult IS NOT NULL AND visible AND dist<=melee_reach
        THEN (doom_prandom(thing_id, tic, 17) % melee_sides + 1)*melee_mult
      -- The barrel's blast falls off with distance.
      WHEN explodes AND visible AND dist<blast_radius
        THEN GREATEST(0,blast_radius-FLOOR(dist)::int)::int
      ELSE 0
    END AS dmg
  FROM hits WHERE melee_mult IS NOT NULL OR explodes
)
INSERT INTO monster_attack_damage
  (map_id, attacker_id, victim_id, victim_player, dmg, mx, my)
SELECT p_map_id::int, d.thing_id, d.victim_id, d.victim_player, d.dmg,
       a.mx, a.my
FROM damage d
JOIN attackers a ON a.thing_id = d.thing_id;

-- the staged rolls landing on a player
WITH
params AS (SELECT p_map_id::int AS map_id, p_player_thing_id::int AS player_thing_id),
-- Every live player on the map. The shove joins this, so a roll staged
-- against a player who has since died lands on nobody.
players AS (
  SELECT ps.player_thing_id, t.x::double precision AS px, t.y::double precision AS py
  FROM player_state ps JOIN params p ON ps.map_id = p.map_id
  JOIN things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
  WHERE ps.alive
),
-- P_DamageMobj's `if (player && gameskill == sk_baby) damage >>= 1`, which
-- runs per hit and before the armour absorbs its third or half. Monster
-- victims (victim_id NOT NULL, the infighting path) never get it.
hurt AS (
  SELECT d.dmg >> CASE WHEN g.skill=0 THEN 1 ELSE 0 END AS dmg,
         d.mx, d.my, d.victim_player
  FROM monster_attack_damage d
  JOIN params p ON d.map_id = p.map_id
  JOIN game_tic_commands g ON g.map_id = p.map_id
   AND g.player_thing_id = d.victim_player
  WHERE d.victim_id IS NULL
),
-- P_DamageMobj shoves the player exactly as it shoves a monster:
-- `thrust = damage*(FRACUNIT>>3)*100/mass` directed away from the inflictor,
-- which for a bullet or a claw is the attacker itself. MT_PLAYER's mass is
-- 100, so the shove is damage/8 map units per tic. It is computed from the
-- damage before the armour absorbs any of it, and it is summed per hit --
-- three shotgun pellets from the same sergeant push three times as hard as
-- one.
shove AS (
  SELECT h.dmg, h.victim_player,
         CASE WHEN r.dist > 0 THEN h.dmg * 0.125 * r.ddx / r.dist
              ELSE 0.0 END AS tx,
         CASE WHEN r.dist > 0 THEN h.dmg * 0.125 * r.ddy / r.dist
              ELSE 0.0 END AS ty
  FROM hurt h
  JOIN players pp ON pp.player_thing_id = h.victim_player
  CROSS JOIN LATERAL (
    SELECT pp.px - h.mx AS ddx, pp.py - h.my AS ddy,
           sqrt(power(pp.px - h.mx, 2) + power(pp.py - h.my, 2)) AS dist
  ) r
),
totaled AS (
  SELECT p_map_id::int AS map_id, victim_player AS player_thing_id,
         SUM(dmg)::int AS total_dmg,
         SUM(FLOOR(dmg/3.0))::int AS green_saved,
         SUM(FLOOR(dmg/2.0))::int AS blue_saved,
         -- 16.16 fixed point, as vanilla accumulates momentum: a float sum of
         -- several hits would depend on the order the rows arrive in.
         SUM(ROUND(tx * 65536.0)) / 65536.0 AS thrust_x,
         SUM(ROUND(ty * 65536.0)) / 65536.0 AS thrust_y
  FROM shove
  GROUP BY victim_player
),
absorbed AS (
  SELECT t.*,
         (ps.god_mode OR ps.invuln_tics > 0) AS blocked,
         CASE WHEN ps.god_mode OR ps.invuln_tics > 0 THEN 0
              ELSE LEAST(ps.armor, CASE ps.armor_class
                     WHEN 2 THEN t.blue_saved WHEN 1 THEN t.green_saved
                     ELSE 0 END)
         END AS saved
  FROM totaled t
  JOIN player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = t.player_thing_id
),
applied AS (
  SELECT a.*, CASE WHEN a.blocked THEN 0 ELSE a.total_dmg - a.saved END AS took
  FROM absorbed a
)
UPDATE player_state ps
SET armor = ps.armor - a.saved,
    armor_class=CASE WHEN ps.armor-a.saved<=0 THEN 0 ELSE ps.armor_class END,
    health = GREATEST(0, ps.health - a.took),
    -- P_DamageMobj: player->damagecount += damage, which reddens the screen.
    damage_count = LEAST(100, ps.damage_count + a.took),
    alive = GREATEST(0, ps.health - a.took) > 0,
    -- Renderer shows the STFOUCH pain face while this is > 0; a fresh hit
    -- always resets it to a full flash.
    pain_face_tics = CASE WHEN a.took > 0 THEN 12
                          ELSE ps.pain_face_tics END,
    -- A monster or a barrel is the world, for the deathmatch scoreboard.
    killer_id = CASE WHEN ps.alive AND ps.health - a.took <= 0 THEN -1
                     ELSE ps.killer_id END,
    momentum_x = (ps.momentum_x + a.thrust_x)::real,
    momentum_y = (ps.momentum_y + a.thrust_y)::real
FROM applied a
WHERE ps.map_id = a.map_id AND ps.player_thing_id = a.player_thing_id;

-- the same rolls, landing on a monster
UPDATE thing_health h
SET health = h.health - v.dmg, alive = h.health - v.dmg > 0
FROM (
  SELECT victim_id, SUM(dmg)::int AS dmg
  FROM monster_attack_damage
  WHERE map_id = p_map_id::int AND victim_id IS NOT NULL
    AND victim_player = p_player_thing_id::int
  GROUP BY victim_id
) v
WHERE h.map_id = p_map_id::int AND h.thing_id = v.victim_id AND v.dmg > 0;

-- the victim turns on whoever shot it
UPDATE monster_ai ai
SET target_thing_id = v.attacker,
    state = CASE WHEN ai.state = 'stand' THEN 'see'::actor_state ELSE ai.state END,
    seq_index = CASE WHEN ai.state = 'stand' THEN 0 ELSE ai.seq_index END,
    state_tics = CASE WHEN ai.state = 'stand' THEN 0 ELSE ai.state_tics END
FROM (
  SELECT victim_id, MIN(attacker_id) AS attacker
  FROM monster_attack_damage
  WHERE map_id = p_map_id::int AND victim_id IS NOT NULL AND dmg > 0
    AND victim_player = p_player_thing_id::int
  GROUP BY victim_id
) v
WHERE ai.map_id = p_map_id::int AND ai.thing_id = v.victim_id
  AND ai.thing_id <> v.attacker
  AND ai.target_thing_id IS DISTINCT FROM v.attacker
  AND EXISTS (SELECT 1 FROM thing_health th
              WHERE th.map_id = ai.map_id AND th.thing_id = ai.thing_id
                AND th.alive);
$doom$;

CREATE OR REPLACE FUNCTION doom_cs_monster_barrel(p_map_id integer)
LANGUAGE cedarscript AS $doom$
-- exploding-barrel radius damage
WITH
params AS (SELECT p_map_id::int AS map_id),
explosions AS (
  SELECT t.id AS source_id, t.x::double precision AS ex,
         t.y::double precision AS ey
  FROM monster_ai ai
  JOIN params p ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=t.type AND cd.explodes
  WHERE ai.fired_this_tick
),
blast AS (SELECT MAX(blast_radius) AS r FROM thing_combat_defs WHERE explodes),
victims AS (
  SELECT DISTINCT h.map_id,h.thing_id,
         t.x::double precision AS vx,t.y::double precision AS vy
  FROM explosions e
  JOIN params p ON TRUE
  CROSS JOIN blast bl
  JOIN things t ON t.map_id=p.map_id
    AND t.x BETWEEN e.ex-bl.r AND e.ex+bl.r
    AND t.y BETWEEN e.ey-bl.r AND e.ey+bl.r
  JOIN thing_health h ON h.map_id=t.map_id AND h.thing_id=t.id AND h.alive
),
blocking_walls AS (
  SELECT DISTINCT ld.x1::double precision AS x1,ld.y1::double precision AS y1,
         ld.x2::double precision AS x2,ld.y2::double precision AS y2
  FROM explosions e
  JOIN params p ON TRUE
  CROSS JOIN blast bl
  JOIN linedef_geom ld ON ld.map_id=p.map_id
  LEFT JOIN sectors fr ON fr.map_id=ld.map_id AND fr.id=ld.fsec
  LEFT JOIN sectors bk ON bk.map_id=ld.map_id AND bk.id=ld.bsec
  WHERE (ld.left_sd_id=-1 OR ld.right_sd_id=-1
     OR fr.id IS NULL OR bk.id IS NULL
     OR LEAST(fr.ceil_height,bk.ceil_height)
          <= GREATEST(fr.floor_height,bk.floor_height))
    -- Both endpoints of any blocked sight line lie within 128 of the blast,
    -- so a wall that can block one has to reach into this box.
    AND LEAST(ld.x1,ld.x2) <= e.ex+bl.r
    AND GREATEST(ld.x1,ld.x2) >= e.ex-bl.r
    AND LEAST(ld.y1,ld.y2) <= e.ey+bl.r
    AND GREATEST(ld.y1,ld.y2) >= e.ey-bl.r
),
radial AS (
  SELECT v.map_id,v.thing_id,
         SUM(GREATEST(0,bl.r-FLOOR(d.dist)::int)::int)::int AS damage
  FROM explosions e CROSS JOIN victims v CROSS JOIN blast bl
  CROSS JOIN LATERAL (
    SELECT SQRT(POWER(v.vx-e.ex,2)+POWER(v.vy-e.ey,2)) AS dist
  ) d
  WHERE v.thing_id<>e.source_id AND d.dist<bl.r
    AND NOT EXISTS (
      SELECT 1 FROM blocking_walls b
      CROSS JOIN LATERAL (
        SELECT
          (e.ex-b.x1)*(b.y2-b.y1)-(e.ey-b.y1)*(b.x2-b.x1) AS d1,
          (v.vx-b.x1)*(b.y2-b.y1)-(v.vy-b.y1)*(b.x2-b.x1) AS d2,
          (b.x1-e.ex)*(v.vy-e.ey)-(b.y1-e.ey)*(v.vx-e.ex) AS d3,
          (b.x2-e.ex)*(v.vy-e.ey)-(b.y2-e.ey)*(v.vx-e.ex) AS d4
      ) sides
      WHERE sides.d1*sides.d2<0 AND sides.d3*sides.d4<0
    )
  GROUP BY v.map_id,v.thing_id
)
UPDATE thing_health h
SET health=h.health-r.damage,alive=h.health-r.damage>0
FROM radial r
WHERE h.map_id=r.map_id AND h.thing_id=r.thing_id;
$doom$;

CREATE OR REPLACE FUNCTION doom_cs_monster_blast(p_map_id integer)
LANGUAGE cedarscript AS $doom$
-- P_DamageMobj's thrust
-- The last thing P_DamageMobj does is shove the target away from whatever hurt
-- it: `thrust = damage*(FRACUNIT>>3)*100/mass`, which is damage*12.5/mass map
-- units a tic, along the angle from the inflictor to the target. It is what
-- makes one barrel throw the next -- and, through the same statement, what
-- makes a rocket knock a trooper back.
WITH
params AS (SELECT p_map_id::int AS map_id),
explosions AS (
  SELECT i.projectile_id, mp.owner_thing_id AS source_id,
         i.x::double precision AS ex, i.y::double precision AS ey
  FROM projectile_impacts i
  JOIN monster_projectiles mp ON mp.map_id=i.map_id
   AND mp.projectile_id=i.projectile_id
  JOIN params p ON i.map_id=p.map_id
  WHERE i.projectile_type='rocket'
  UNION ALL
  SELECT -ai.thing_id, ai.thing_id, t.x::double precision, t.y::double precision
  FROM monster_ai ai
  JOIN params p ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=t.type AND cd.explodes
  WHERE ai.fired_this_tick
),
shoved AS (
  SELECT v.id AS thing_id,
         SUM(ROUND(GREATEST(0,128-FLOOR(d.dist)::int) * 12.5
             / GREATEST(1,cd.mass) * d.dx / NULLIF(d.dist,0) * 65536.0)) / 65536.0 AS push_x,
         SUM(ROUND(GREATEST(0,128-FLOOR(d.dist)::int) * 12.5
             / GREATEST(1,cd.mass) * d.dy / NULLIF(d.dist,0) * 65536.0)) / 65536.0 AS push_y
  FROM explosions e
  JOIN things v ON v.map_id=p_map_id::int
  JOIN thing_combat_defs cd ON cd.thing_type=v.type
  CROSS JOIN LATERAL (
    SELECT v.x-e.ex AS dx, v.y-e.ey AS dy,
           SQRT(POWER(v.x-e.ex,2)+POWER(v.y-e.ey,2)) AS dist
  ) d
  WHERE v.id<>e.source_id AND d.dist<128.0 AND d.dist>0.0
  GROUP BY v.id
)
UPDATE things t
SET mom_x = (t.mom_x + s.push_x)::real,
    mom_y = (t.mom_y + s.push_y)::real
FROM shoved s
WHERE t.map_id=p_map_id::int AND t.id=s.thing_id;
$doom$;

-- Record corpses that have settled and pick this tic's P_NightmareRespawn
-- set. Returns whether anything was picked, which gates doom_cs_monster_respawn.
CREATE OR REPLACE FUNCTION doom_cs_monster_deaths(p_map_id integer, p_player_thing_id integer) RETURNS boolean
LANGUAGE cedarscript AS $doom$
let monster_respawn_tics = doom_const('MONSTER_RESPAWN_TICS');
-- record when a corpse settled
INSERT INTO monster_deaths (map_id,thing_id,death_tic)
SELECT ai.map_id,ai.thing_id,ps.level_tics
FROM monster_ai ai
JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
JOIN thing_combat_defs d ON d.thing_type=t.type AND d.counts_kill
JOIN player_state ps ON ps.map_id=ai.map_id
  AND ps.player_thing_id=p_player_thing_id::int
WHERE ai.map_id=p_map_id::int AND ai.state='dead'
ON CONFLICT (map_id,thing_id) DO NOTHING;

-- choose this tic's P_NightmareRespawn set
-- movecount >= 12*TICRATE, then a check only on every 32nd tic, then
-- P_Random() <= 4 -- five values in 256, rolled per corpse. Staged into a
-- table because the statements below all have to agree on the same set.
DELETE FROM monster_respawns WHERE map_id=p_map_id::int;

INSERT INTO monster_respawns (map_id,thing_id,old_x,old_y)
SELECT md.map_id,md.thing_id,t.x,t.y
FROM monster_deaths md
JOIN things t ON t.map_id=md.map_id AND t.id=md.thing_id
JOIN player_state ps ON ps.map_id=md.map_id
  AND ps.player_thing_id=p_player_thing_id::int
WHERE md.map_id=p_map_id::int
  AND ((SELECT g.skill FROM game_tic_commands g
             WHERE g.map_id=p_map_id::int
               AND g.player_thing_id=p_player_thing_id::int)=4
       -- -respawn: the same rule on any skill
       OR EXISTS (SELECT 1 FROM mp_match m WHERE m.map_id=p_map_id::int AND m.respawn_monsters))
  AND ps.level_tics - md.death_tic >= monster_respawn_tics
  AND (ps.level_tics & 31) = 0
  AND doom_prandom(md.thing_id, ps.level_tics, 40) <= 4
  -- P_CheckPosition: no respawn while something else is standing on the spot.
  AND NOT EXISTS (
    SELECT 1
    FROM thing_health oh
    JOIN things ot ON ot.map_id=oh.map_id AND ot.id=oh.thing_id
    JOIN thing_combat_defs od ON od.thing_type=ot.type
    JOIN thing_combat_defs md2 ON md2.thing_type=t.type
    WHERE oh.map_id=md.map_id AND oh.alive AND oh.thing_id<>md.thing_id
      AND POWER(ot.x-t.spawn_x,2)+POWER(ot.y-t.spawn_y,2)
            < POWER(od.radius+md2.radius,2)
  );
let mut any_respawn = false;
SELECT EXISTS (SELECT 1 FROM monster_respawns WHERE map_id=p_map_id) AS e
  { any_respawn = e; }
return any_respawn;
$doom$;

CREATE OR REPLACE FUNCTION doom_cs_monster_respawn(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let respawn_fog_base = doom_const('MONSTER_RESPAWN_EFFECT_ID_BASE');
let tic_span = doom_const('EFFECT_ID_TIC_SPAN');
-- teleport fog, old spot and new
-- P_NightmareRespawn spawns an MT_TFOG at each end and starts sfx_telept on
-- both.
INSERT INTO world_effects (map_id, effect_id, effect_type, x, y, z, sector_id, age)
SELECT r.map_id, respawn_fog_base::bigint + r.thing_id::bigint * tic_span * 2
                 + (ps.level_tics % tic_span) * 2 + e.k,
       'tfog', CASE e.k WHEN 0 THEN r.old_x ELSE t.spawn_x::real END,
       CASE e.k WHEN 0 THEN r.old_y ELSE t.spawn_y::real END,
       s.floor_height, CASE e.k WHEN 0 THEN rt.sector_id ELSE rt.spawn_sector_id END, 0
FROM monster_respawns r
JOIN things t ON t.map_id=r.map_id AND t.id=r.thing_id
JOIN render_things rt ON rt.map_id=r.map_id AND rt.thing_id=r.thing_id
JOIN player_state ps ON ps.map_id=r.map_id AND ps.player_thing_id=p_player_thing_id::int
CROSS JOIN (VALUES (0), (1)) AS e (k)
JOIN sectors s ON s.map_id=r.map_id
 AND s.id=CASE e.k WHEN 0 THEN rt.sector_id ELSE COALESCE(rt.spawn_sector_id, rt.sector_id) END
WHERE r.map_id=p_map_id::int
ON CONFLICT (map_id, effect_id) DO NOTHING;

INSERT INTO sound_events
  (map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y)
SELECT r.map_id,'respawn-out:'||r.thing_id::text||':'||ps.level_tics::text,
       ps.level_tics,'DSTELEPT',r.thing_id,r.old_x,r.old_y
FROM monster_respawns r
JOIN player_state ps ON ps.map_id=r.map_id
  AND ps.player_thing_id=p_player_thing_id::int
WHERE r.map_id=p_map_id::int
UNION ALL
SELECT r.map_id,'respawn-in:'||r.thing_id::text||':'||ps.level_tics::text,
       ps.level_tics,'DSTELEPT',r.thing_id,t.spawn_x::real,t.spawn_y::real
FROM monster_respawns r
JOIN things t ON t.map_id=r.map_id AND t.id=r.thing_id
JOIN player_state ps ON ps.map_id=r.map_id
  AND ps.player_thing_id=p_player_thing_id::int
WHERE r.map_id=p_map_id::int
ON CONFLICT (map_id,event_key) DO NOTHING;

-- Its sight and death cues are latched by a stable per-monster key, so they
-- have to be released or the monster comes back mute for the rest of the map.
DELETE FROM sound_events e
USING monster_respawns r
WHERE e.map_id=r.map_id AND r.map_id=p_map_id::int
  AND e.event_key IN ('mon-sight:'||r.thing_id::text,
                      'mon-death:'||r.thing_id::text);

-- put the monster back
UPDATE things t
SET x=t.spawn_x, y=t.spawn_y, angle=t.spawn_angle
FROM monster_respawns r
WHERE t.map_id=r.map_id AND t.id=r.thing_id AND r.map_id=p_map_id::int;

UPDATE thing_health h
SET health=h.max_health, alive=TRUE
FROM monster_respawns r
WHERE h.map_id=r.map_id AND h.thing_id=r.thing_id AND r.map_id=p_map_id::int;

-- Back to sleep at the spawn point, exactly as P_SpawnMobj leaves it
UPDATE render_things rt
SET sector_id=rt.spawn_sector_id
FROM monster_respawns r
WHERE rt.map_id=r.map_id AND rt.thing_id=r.thing_id AND r.map_id=p_map_id::int
  AND rt.spawn_sector_id IS NOT NULL AND rt.sector_id<>rt.spawn_sector_id;

UPDATE monster_ai ai
SET state='stand', state_tics=-1, seq_index=0, attack_cooldown=18,
    fired_this_tick=FALSE, sector_id=rt.sector_id
FROM monster_respawns r
JOIN render_things rt ON rt.map_id=r.map_id AND rt.thing_id=r.thing_id
WHERE ai.map_id=r.map_id AND ai.thing_id=r.thing_id AND r.map_id=p_map_id::int;

DELETE FROM monster_deaths d
USING monster_respawns r
WHERE d.map_id=r.map_id AND d.thing_id=r.thing_id AND r.map_id=p_map_id::int;
$doom$;

-- The pipeline. Nine of the eleven stages used to open with an EXISTS of
-- their own; doom_cs_monster_plan answers all of them in two statements.
CREATE OR REPLACE FUNCTION doom_cs_monsters(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let pre = doom_cs_monster_plan(p_map_id);
doom_cs_monster_retarget(p_map_id,p_player_thing_id);
if (pre & 1) <> 0 { doom_cs_monster_noise(p_map_id); }
doom_cs_monster_think(p_map_id,p_player_thing_id);

-- Re-planned: every bit below is a question about the state the think stage
-- has just written.
let plan = doom_cs_monster_plan(p_map_id);

-- Last tic's staging is cleared whether or not anyone steps this tic, or the
-- move stage would replay it.
DELETE FROM monster_steps WHERE map_id=p_map_id;
let mut stepped = false;
if (plan & 2) <> 0 { stepped = doom_cs_monster_step(p_map_id,p_player_thing_id); }
if stepped { doom_cs_monster_move(p_map_id,p_player_thing_id); }

if (plan & 4) <> 0 { doom_cs_monster_float(p_map_id,p_player_thing_id); }
if (plan & 8) <> 0 { doom_cs_monster_chase(p_map_id,p_player_thing_id); }
if (plan & 16) <> 0 { doom_cs_monster_attack(p_map_id,p_player_thing_id); }
if (plan & 32) <> 0 { doom_cs_monster_barrel(p_map_id); }
if (plan & 64) <> 0 { doom_cs_monster_blast(p_map_id); }

let respawning = doom_cs_monster_deaths(p_map_id,p_player_thing_id);
if respawning { doom_cs_monster_respawn(p_map_id,p_player_thing_id); }
$doom$;
