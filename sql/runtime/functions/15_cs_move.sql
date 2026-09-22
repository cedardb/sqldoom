CREATE OR REPLACE FUNCTION doom_cs_move(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let player_radius = doom_const('PLAYER_RADIUS');
let player_height = doom_const('PLAYER_HEIGHT');
let max_step = doom_const('MAXSTEP');
let view_height = doom_const('VIEWHEIGHT');
let friction = doom_const('FRICTION');
let stop_speed = doom_const('STOPSPEED');
let max_move = doom_const('MAXMOVE');
let forwardmove = doom_const('FORWARDMOVE');
let forwardmove_run = doom_const('FORWARDMOVE_RUN');
let sidemove = doom_const('SIDEMOVE');
let sidemove_run = doom_const('SIDEMOVE_RUN');
let thrust_unit = doom_const('THRUST_UNIT');
let max_bob = doom_const('MAXBOB');
let gravity = doom_const('GRAVITY');
let bob_factor = doom_const('BOB_FACTOR');
let bob_period = doom_const('BOB_PERIOD_TICS');
let block_margin = doom_const('BLOCK_MARGIN');
let pos_epsilon = doom_const('POS_EPSILON');
-- One prepared 35 Hz player movement tick.
--
WITH
params AS (
  SELECT
    g.map_id,
    g.player_thing_id,
    g.move_fwd::float8 AS move_fwd,
    g.move_strafe::float8 AS move_side,
    g.running,
    g.turn_degrees::float8 AS turn_degrees,
    player_radius AS radius,
    ps2.noclip,
    player_height AS player_h,
    max_step AS max_step,
    view_height AS eye_h,
    friction AS friction,
    stop_speed AS stop_speed,
    max_move AS max_move,
    max_bob AS max_bob,
    gravity AS gravity
  FROM game_tic_commands g
  JOIN player_state ps2 ON ps2.map_id=g.map_id
   AND ps2.player_thing_id=g.player_thing_id
  WHERE g.map_id=p_map_id::int AND g.player_thing_id=p_player_thing_id::int
    AND g.movement_mode='full'
),
current_pose AS (
  SELECT p.*,t.x::float8 AS px,t.y::float8 AS py,t.angle::float8 AS old_angle,
         ps.momentum_x::float8 AS old_mom_x,
         ps.momentum_y::float8 AS old_mom_y,
         ps.momentum_z::float8 AS old_mom_z,
         (ps.base_z-p.eye_h)::float8 AS feet_z,
         (ps.momentum_z=0) AS on_ground,
         ps.level_tics,
         CASE WHEN p.running THEN forwardmove_run ELSE forwardmove END
           * thrust_unit AS forward_thrust,
         CASE WHEN p.running THEN sidemove_run ELSE sidemove END
           * thrust_unit AS side_thrust
  FROM params p
  JOIN things t ON t.map_id=p.map_id AND t.id=p.player_thing_id
  JOIN player_state ps ON ps.map_id=p.map_id
    AND ps.player_thing_id=p.player_thing_id
),
turned AS (
  SELECT c.*,
         (c.old_angle-c.turn_degrees)
           - 360.0*FLOOR((c.old_angle-c.turn_degrees)/360.0) AS new_angle
  FROM current_pose c
),
thrusted AS (
  SELECT t.*,
         LEAST(t.max_move,GREATEST(-t.max_move,
           t.old_mom_x
           + CASE WHEN t.on_ground THEN
               t.move_fwd*t.forward_thrust*COS(RADIANS(t.new_angle))
               + t.move_side*t.side_thrust*SIN(RADIANS(t.new_angle))
             ELSE 0.0 END)) AS raw_mom_x,
         LEAST(t.max_move,GREATEST(-t.max_move,
           t.old_mom_y
           + CASE WHEN t.on_ground THEN
               t.move_fwd*t.forward_thrust*SIN(RADIANS(t.new_angle))
               - t.move_side*t.side_thrust*COS(RADIANS(t.new_angle))
             ELSE 0.0 END)) AS raw_mom_y
  FROM turned t
),
lines_here AS (
  SELECT ld.linedef_id AS id,ld.flags,ld.left_sd_id,ld.right_sd_id,
         ld.x1::float8 AS x1,ld.y1::float8 AS y1,
         ld.x2::float8 AS x2,ld.y2::float8 AS y2,
         sf.floor_height AS f_floor,sf.ceil_height AS f_ceil,
         sb.floor_height AS b_floor,sb.ceil_height AS b_ceil
  FROM params p
  JOIN linedef_geom ld ON ld.map_id=p.map_id
  LEFT JOIN sectors sf ON sf.map_id=ld.map_id AND sf.id=ld.fsec
  LEFT JOIN sectors sb ON sb.map_id=ld.map_id AND sb.id=ld.bsec
),
blocking AS (
  SELECT lg.x1,lg.y1,lg.x2,lg.y2
  FROM lines_here lg
  -- P_BlockLinesIterator only visits the lines in the blockmap cells the move
  -- touches. There is no blockmap here, so bound it the same way: every
  -- candidate position lies between (px,py) and (px+mom,py+mom), and a line
  -- can only block one by coming within the 16-unit collision radius of it,
  -- so nothing outside this box is reachable this tic.
  WHERE LEAST(lg.x1,lg.x2)
          <= (SELECT GREATEST(t.px,t.px+t.raw_mom_x)+t.radius+2.0
              FROM thrusted t)
    AND GREATEST(lg.x1,lg.x2)
          >= (SELECT LEAST(t.px,t.px+t.raw_mom_x)-t.radius-2.0
              FROM thrusted t)
    AND LEAST(lg.y1,lg.y2)
          <= (SELECT GREATEST(t.py,t.py+t.raw_mom_y)+t.radius+2.0
              FROM thrusted t)
    AND GREATEST(lg.y1,lg.y2)
          >= (SELECT LEAST(t.py,t.py+t.raw_mom_y)-t.radius-2.0
              FROM thrusted t)
    -- The reasons a line blocks.
    AND (lg.left_sd_id=-1 OR lg.right_sd_id=-1 OR (lg.flags & 1)<>0
      -- P_TryMove: the opening has to be tall enough to stand in.
      OR (lg.b_ceil IS NOT NULL AND lg.f_ceil IS NOT NULL
          AND lg.b_floor IS NOT NULL AND lg.f_floor IS NOT NULL
          AND LEAST(lg.f_ceil,lg.b_ceil)-GREATEST(lg.f_floor,lg.b_floor)<player_height)
      -- P_TryMove blocks a step UP over 24 units, measured from the thing's
      -- feet. It does NOT block a drop.
      OR (lg.b_floor IS NOT NULL AND lg.f_floor IS NOT NULL
          AND GREATEST(lg.b_floor,lg.f_floor)
              > (SELECT c.feet_z+c.max_step FROM current_pose c)))
),
-- PIT_CheckThing. Doom blocks on a bounding box: A move is refused when the
-- two boxes overlap on BOTH axes.
-- Only solid things block -- monsters and barrels while they live;
-- P_KillMobj clears MF_SOLID, so a corpse is walked over.
-- Solid decorations -- lamps, pillars, firesticks -- have no health to be
-- alive or dead, so they come from thing_blocking_defs instead and block
-- unconditionally.
blocking_things AS (
  SELECT tt.x::float8 AS tx, tt.y::float8 AS ty,
         (COALESCE(cd.radius, bd.radius) + player_radius)::float8 AS blockdist
  FROM things tt
  LEFT JOIN thing_combat_defs cd ON cd.thing_type = tt.type
  LEFT JOIN thing_health hh ON hh.map_id = tt.map_id AND hh.thing_id = tt.id
  LEFT JOIN thing_blocking_defs bd ON bd.thing_type = tt.type
  WHERE tt.map_id = p_map_id::int
    AND tt.id <> p_player_thing_id::int
    AND (
      -- An actor, for as long as it lives.
      (cd.thing_type IS NOT NULL AND hh.alive)
      -- Or a decoration Doom marks MF_SOLID. One that the skill or the
      -- multiplayer flag kept from spawning is not in the level, so it
      -- cannot block either.
      OR (bd.thing_type IS NOT NULL AND (tt.flags & 16) = 0
          AND (tt.flags & (SELECT g.skill_bit FROM game_tic_commands g
                           WHERE g.map_id = p_map_id::int
                             AND g.player_thing_id = p_player_thing_id::int)) <> 0))
    AND tt.x <= (SELECT GREATEST(w.px,w.px+w.raw_mom_x) FROM thrusted w)
                + COALESCE(cd.radius, bd.radius) + player_radius + block_margin
    AND tt.x >= (SELECT LEAST(w.px,w.px+w.raw_mom_x) FROM thrusted w)
                - COALESCE(cd.radius, bd.radius) - player_radius - block_margin
    AND tt.y <= (SELECT GREATEST(w.py,w.py+w.raw_mom_y) FROM thrusted w)
                + COALESCE(cd.radius, bd.radius) + player_radius + block_margin
    AND tt.y >= (SELECT LEAST(w.py,w.py+w.raw_mom_y) FROM thrusted w)
                - COALESCE(cd.radius, bd.radius) - player_radius - block_margin
  UNION ALL
  -- The other players of a deathmatch, MF_SOLID with a 16-unit radius.
  SELECT ot.x::float8, ot.y::float8, (player_radius*2)::float8
  FROM player_state op
  JOIN things ot ON ot.map_id=op.map_id AND ot.id=op.player_thing_id
  WHERE op.map_id = p_map_id::int
    AND op.player_thing_id <> p_player_thing_id::int AND op.alive
),

candidates AS (
  SELECT 1 AS pri,t.px+t.raw_mom_x AS cx,t.py+t.raw_mom_y AS cy
  FROM thrusted t
  UNION ALL
  SELECT 2,t.px+t.raw_mom_x,t.py FROM thrusted t
  UNION ALL
  SELECT 3,t.px,t.py+t.raw_mom_y FROM thrusted t
  UNION ALL
  SELECT 4,t.px,t.py FROM thrusted t
),
candidate_blocked AS (
  SELECT c.pri,c.cx,c.cy,
         (count(*) FILTER (WHERE d.dist<p.radius AND d.dist<d0.dist)>0
           OR count(*) FILTER (WHERE xing.intersects)>0
           OR count(*) FILTER (WHERE ABS(c.cx-bt.tx) < bt.blockdist
                                 AND ABS(c.cy-bt.ty) < bt.blockdist)>0
           ) AND NOT p.noclip AS blocked
  FROM candidates c
  CROSS JOIN params p
  LEFT JOIN blocking b ON TRUE
  LEFT JOIN blocking_things bt ON TRUE
  CROSS JOIN LATERAL (
    SELECT LEAST(1.0,GREATEST(0.0,
      ((c.cx-b.x1)*(b.x2-b.x1)+(c.cy-b.y1)*(b.y2-b.y1))
      / NULLIF(POWER(b.x2-b.x1,2)+POWER(b.y2-b.y1,2),0.0)
    )) AS t
  ) lt
  CROSS JOIN LATERAL (
    SELECT SQRT(POWER(c.cx-(b.x1+lt.t*(b.x2-b.x1)),2)
              + POWER(c.cy-(b.y1+lt.t*(b.y2-b.y1)),2)) AS dist
  ) d
  CROSS JOIN LATERAL (
    SELECT LEAST(1.0,GREATEST(0.0,
      ((p0.px-b.x1)*(b.x2-b.x1)+(p0.py-b.y1)*(b.y2-b.y1))
      / NULLIF(POWER(b.x2-b.x1,2)+POWER(b.y2-b.y1,2),0.0)
    )) AS t
    FROM thrusted p0
  ) lt0
  CROSS JOIN LATERAL (
    SELECT SQRT(POWER(p0.px-(b.x1+lt0.t*(b.x2-b.x1)),2)
              + POWER(p0.py-(b.y1+lt0.t*(b.y2-b.y1)),2)) AS dist
    FROM thrusted p0
  ) d0
  CROSS JOIN LATERAL (
    SELECT
      (p0.px-b.x1)*(b.y2-b.y1)-(p0.py-b.y1)*(b.x2-b.x1) AS d1,
      (c.cx-b.x1)*(b.y2-b.y1)-(c.cy-b.y1)*(b.x2-b.x1) AS d2,
      (b.x1-p0.px)*(c.cy-p0.py)-(b.y1-p0.py)*(c.cx-p0.px) AS d3,
      (b.x2-p0.px)*(c.cy-p0.py)-(b.y2-p0.py)*(c.cx-p0.px) AS d4
    FROM thrusted p0
  ) sides
  CROSS JOIN LATERAL (
    SELECT sides.d1*sides.d2<0 AND sides.d3*sides.d4<0 AS intersects
  ) xing
  GROUP BY c.pri,c.cx,c.cy
),
best_pos AS (
  SELECT cx,cy FROM candidate_blocked WHERE NOT blocked ORDER BY pri LIMIT 1
),
sector_floor AS (
  SELECT s.id AS sector_id,s.floor_height
  FROM params p CROSS JOIN best_pos bp
  JOIN sectors s ON s.map_id=p.map_id
   AND s.id=doom_sector_at(p.map_id,bp.cx,bp.cy)
),
resolved AS (
  SELECT t.*,bp.cx,bp.cy,sf.sector_id,
         z.feet+t.eye_h AS base_z,z.next_mom_z,
         LEAST((POWER(t.raw_mom_x,2)+POWER(t.raw_mom_y,2))/bob_factor,
               t.max_bob) AS bob_strength,
         CASE WHEN ABS(bp.cx-(t.px+t.raw_mom_x))<pos_epsilon
              THEN t.raw_mom_x ELSE 0.0 END AS slide_mom_x,
         CASE WHEN ABS(bp.cy-(t.py+t.raw_mom_y))<pos_epsilon
              THEN t.raw_mom_y ELSE 0.0 END AS slide_mom_y
  FROM thrusted t CROSS JOIN best_pos bp CROSS JOIN sector_floor sf
  -- P_ZMovement: apply the pending fall, land if that reaches the floor,
  -- otherwise accelerate downward. Stepping up still snaps instantly.
  CROSS JOIN LATERAL (
    SELECT
      CASE WHEN t.feet_z+t.old_mom_z<=sf.floor_height
           THEN sf.floor_height::float8
           ELSE t.feet_z+t.old_mom_z END AS feet,
      CASE WHEN t.feet_z+t.old_mom_z<=sf.floor_height THEN 0.0
           WHEN t.old_mom_z=0.0 THEN -2.0*t.gravity
           ELSE t.old_mom_z-t.gravity END AS next_mom_z
  ) z
),
motion AS (
  SELECT r.*,
         (r.bob_strength/2.0)
           * SIN(2.0*PI()*r.level_tics/bob_period) AS bob_offset,
         CASE
           WHEN NOT r.on_ground THEN r.slide_mom_x
           WHEN r.move_fwd=0 AND r.move_side=0
            AND ABS(r.slide_mom_x)<r.stop_speed
            AND ABS(r.slide_mom_y)<r.stop_speed THEN 0.0
           ELSE r.slide_mom_x*r.friction
         END AS next_mom_x,
         CASE
           WHEN NOT r.on_ground THEN r.slide_mom_y
           WHEN r.move_fwd=0 AND r.move_side=0
            AND ABS(r.slide_mom_x)<r.stop_speed
            AND ABS(r.slide_mom_y)<r.stop_speed THEN 0.0
           ELSE r.slide_mom_y*r.friction
         END AS next_mom_y
  FROM resolved r
)
UPDATE player_state ps
SET previous_x=m.px,previous_y=m.py,
    position_x=m.cx,position_y=m.cy,
    base_z=m.base_z,view_z=m.base_z+m.bob_offset,
    view_angle=m.new_angle,
    previous_view_z=ps.view_z,previous_view_angle=ps.view_angle,
    momentum_x=m.next_mom_x,momentum_y=m.next_mom_y,
    momentum_z=m.next_mom_z,
    bob_strength=m.bob_strength,
    sector_id=m.sector_id
FROM motion m
WHERE ps.map_id=m.map_id AND ps.player_thing_id=m.player_thing_id;

UPDATE things t
SET x=ps.position_x,y=ps.position_y,z=ps.view_z,angle=ps.view_angle
FROM player_state ps
WHERE t.map_id=p_map_id::int AND t.id=p_player_thing_id::int
  AND ps.map_id=t.map_id AND ps.player_thing_id=t.id
  AND EXISTS (
    SELECT 1 FROM game_tic_commands g
    WHERE g.map_id=t.map_id AND g.player_thing_id=t.id
      AND g.movement_mode='full'
  );
$doom$;
