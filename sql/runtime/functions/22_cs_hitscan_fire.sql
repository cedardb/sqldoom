CREATE OR REPLACE FUNCTION doom_cs_hitscan_fire(p_map_id integer, p_player_thing_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
let mut impact_count = 0;
let player_radius = doom_const('PLAYER_RADIUS');
let player_height = doom_const('PLAYER_HEIGHT');
let view_height = doom_const('VIEWHEIGHT');
let attack_z_offset = doom_const('ATTACK_Z_OFFSET');
let aim_spread = doom_const('AIM_SPREAD_DEGREES');
let autoaim_slope = doom_const('AUTOAIM_SLOPE');
let slope_unbounded = doom_const('SLOPE_UNBOUNDED');
let spread_units = doom_const('GUNSHOT_SPREAD_UNITS');
-- Fire one hitscan weapon blast (fist/pistol/shotgun/chaingun/chainsaw)
WITH
input AS (
  SELECT pw.map_id,pw.player_thing_id AS player_id,
         RADIANS(t.angle::double precision) AS view_angle,
         (ps.base_z - view_height + player_height/2.0
          + attack_z_offset)::double precision AS shoot_z,
         pw.shot_serial,wd.pellet_count,wd.max_range,
         wd.dmg_dice_count,wd.dmg_dice_mult
  FROM player_weapons pw
  JOIN weapon_defs wd ON wd.weapon_id=pw.current_weapon
  JOIN things t ON t.map_id=pw.map_id AND t.id=pw.player_thing_id
  JOIN player_state ps ON ps.map_id=pw.map_id
    AND ps.player_thing_id=pw.player_thing_id
  WHERE pw.map_id=p_map_id::int AND pw.player_thing_id=p_player_thing_id::int
    AND pw.fired_this_tick AND wd.pellet_count>0
),
shooter AS (
  SELECT i.*, t.x::double precision AS px, t.y::double precision AS py
  FROM input i
  JOIN things t ON t.map_id = i.map_id AND t.id = i.player_id
),
targets AS (
  SELECT t.id AS thing_id, t.x::double precision AS x,
         t.y::double precision AS y, d.radius::double precision AS radius,
         s.floor_height::double precision AS base_z,
         rt.thing_height::double precision AS height, rt.sector_id,
         d.no_blood
  FROM input i
  JOIN thing_health h ON h.map_id = i.map_id AND h.alive
  JOIN things t ON t.map_id = h.map_id AND t.id = h.thing_id
  JOIN thing_combat_defs d ON d.thing_type = t.type
  JOIN render_things rt ON rt.map_id = t.map_id AND rt.thing_id = t.id
  JOIN sectors s ON s.map_id = rt.map_id AND s.id = rt.sector_id
  UNION ALL
  -- The other players of a deathmatch: a player's own radius and height,
  -- standing on their sector's floor, and they bleed.
  SELECT ps.player_thing_id, t.x::double precision, t.y::double precision,
         player_radius::double precision,
         (ps.base_z - view_height)::double precision,
         player_height::double precision, ps.sector_id, FALSE
  FROM input i
  JOIN player_state ps ON ps.map_id = i.map_id
   AND ps.player_thing_id <> i.player_id AND ps.alive
  JOIN things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
),
map_lines AS (
  SELECT ld.linedef_id AS line_id,
         ld.x1::double precision AS x1, ld.y1::double precision AS y1,
         ld.x2::double precision AS x2, ld.y2::double precision AS y2,
         ld.fsec AS right_sector, ld.bsec AS left_sector,
         GREATEST(rsec.floor_height, lsec.floor_height)::double precision
           AS open_bottom,
         LEAST(rsec.ceil_height, lsec.ceil_height)::double precision AS open_top,
         rsec.floor_height<>lsec.floor_height AS floors_differ,
         rsec.ceil_height<>lsec.ceil_height AS ceils_differ
  FROM input i
  JOIN linedef_geom ld ON ld.map_id = i.map_id
  LEFT JOIN sectors rsec ON rsec.map_id = ld.map_id AND rsec.id = ld.fsec
  LEFT JOIN sectors lsec ON lsec.map_id = ld.map_id AND lsec.id = ld.bsec
),
-- P_BulletSlope tries straight ahead, then one spread either side.
aim_rays(priority, angle) AS (
  SELECT 0, 0.0::double precision
  UNION ALL SELECT 1, RADIANS(aim_spread)
  UNION ALL SELECT 2, RADIANS(-aim_spread)
),
aim_target_intersections AS (
  SELECT a.priority, a.angle, t.*,
         g.along - SQRT(GREATEST(0.0, t.radius*t.radius - g.perp2)) AS distance
  FROM shooter p
  CROSS JOIN aim_rays a
  CROSS JOIN targets t
  CROSS JOIN LATERAL (
    SELECT
      (t.x-p.px)*COS(p.view_angle+a.angle)
        + (t.y-p.py)*SIN(p.view_angle+a.angle) AS along,
      POWER(-(t.x-p.px)*SIN(p.view_angle+a.angle)
        + (t.y-p.py)*COS(p.view_angle+a.angle), 2) AS perp2
  ) g
  WHERE g.along > 0 AND g.along <= p.max_range + t.radius
    AND g.perp2 <= t.radius*t.radius
),
-- P_AimLineAttack carries a vertical slope window (starting at Doom's +-100/160 autoaim cone) and
-- narrows it at every two-sided line the trace crosses -- up to the step, down
-- to the header -- then aims at the middle of whatever band of the target is
-- still inside the window.
aim_window AS (
  SELECT h.*, p.shoot_z,
         COALESCE(w.solid,FALSE) AS solid,
         GREATEST(-autoaim_slope, COALESCE(w.max_bottom, -slope_unbounded)) AS bslope,
         LEAST(autoaim_slope, COALESCE(w.min_top, slope_unbounded)) AS tslope
  FROM aim_target_intersections h
  CROSS JOIN shooter p
  CROSS JOIN LATERAL (
    SELECT
      MAX(CASE WHEN l.right_sector IS NULL OR l.left_sector IS NULL
                 OR l.open_bottom>=l.open_top THEN 1 ELSE 0 END)=1 AS solid,
      MAX(CASE WHEN l.floors_differ
               THEN (l.open_bottom-p.shoot_z)/q.ray_t END) AS max_bottom,
      MIN(CASE WHEN l.ceils_differ
               THEN (l.open_top-p.shoot_z)/q.ray_t END) AS min_top
    FROM map_lines l
    CROSS JOIN LATERAL (
      SELECT
        ((l.x1-p.px)*(l.y2-l.y1) - (l.y1-p.py)*(l.x2-l.x1))
          / NULLIF(COS(p.view_angle+h.angle)*(l.y2-l.y1)
            - SIN(p.view_angle+h.angle)*(l.x2-l.x1), 0.0) AS ray_t,
        ((l.x1-p.px)*SIN(p.view_angle+h.angle)
            - (l.y1-p.py)*COS(p.view_angle+h.angle))
          / NULLIF(COS(p.view_angle+h.angle)*(l.y2-l.y1)
            - SIN(p.view_angle+h.angle)*(l.x2-l.x1), 0.0) AS line_u
    ) q
    WHERE q.ray_t > 0 AND q.ray_t < h.distance
      AND q.line_u BETWEEN 0 AND 1
  ) w
  WHERE h.distance > 0 AND h.distance <= p.max_range
),
visible_aim_targets AS (
  SELECT w.*,
         (LEAST(b.thing_top,w.tslope)
          + GREATEST(b.thing_bot,w.bslope)) / 2.0 AS aimslope
  FROM aim_window w
  CROSS JOIN LATERAL (
    SELECT (w.base_z+w.height-w.shoot_z)/w.distance AS thing_top,
           (w.base_z-w.shoot_z)/w.distance AS thing_bot
  ) b
  WHERE NOT w.solid AND w.tslope > w.bslope
    AND b.thing_top >= w.bslope AND b.thing_bot <= w.tslope
),
aim AS (
  SELECT COALESCE((
    SELECT v.aimslope
    FROM visible_aim_targets v
    ORDER BY v.priority, v.distance, v.thing_id
    LIMIT 1
  ), 0.0) AS slope
),
pellet_random AS (
  -- P_GunShot: two draws for the spread and one for the damage, per pellet.
  SELECT pellet,
         doom_prandom(i.shot_serial, pellet, 2) AS r1,
         doom_prandom(i.shot_serial, pellet, 3) AS r2,
         i.dmg_dice_mult
           * (doom_prandom(i.shot_serial, pellet, 4) % i.dmg_dice_count + 1)
           AS damage
  FROM input i
  CROSS JOIN LATERAL generate_series(0, i.pellet_count - 1) pellet
),
pellets AS (
  SELECT r.pellet, r.damage, a.slope,
         p.view_angle + RADIANS((r.r1-r.r2) * 360.0 / spread_units) AS angle
  FROM pellet_random r CROSS JOIN aim a CROSS JOIN shooter p
),
pellet_target_hits AS (
  SELECT b.pellet, b.damage, t.thing_id, t.sector_id, t.no_blood,
         tdist.distance, b.angle, b.slope, 'target'::text AS hit_kind,
         NULL::int AS line_id,NULL::boolean AS line_from_front
  FROM pellets b CROSS JOIN shooter p CROSS JOIN targets t
  CROSS JOIN LATERAL (
    SELECT
      (t.x-p.px)*COS(b.angle)+(t.y-p.py)*SIN(b.angle) AS along,
      POWER(-(t.x-p.px)*SIN(b.angle)+(t.y-p.py)*COS(b.angle), 2) AS perp2
  ) g
  CROSS JOIN LATERAL (
    SELECT g.along-SQRT(GREATEST(0.0,t.radius*t.radius-g.perp2)) AS distance
  ) tdist
  WHERE g.along > 0 AND g.perp2 <= t.radius*t.radius
    AND tdist.distance > 0 AND tdist.distance <= p.max_range
    AND p.shoot_z + b.slope*tdist.distance BETWEEN t.base_z AND t.base_z+t.height
),
pellet_wall_hits AS (
  SELECT b.pellet, b.damage, NULL::int AS thing_id,
         COALESCE(l.right_sector, l.left_sector) AS sector_id,
         TRUE AS no_blood, q.distance, b.angle, b.slope,
         'wall'::text AS hit_kind,l.line_id,
         ((l.x2-l.x1)*(p.py-l.y1)-(l.y2-l.y1)*(p.px-l.x1))<0
           AS line_from_front
  FROM pellets b CROSS JOIN shooter p CROSS JOIN map_lines l
  CROSS JOIN LATERAL (
    SELECT
      ((l.x1-p.px)*(l.y2-l.y1) - (l.y1-p.py)*(l.x2-l.x1))
        / NULLIF(COS(b.angle)*(l.y2-l.y1)-SIN(b.angle)*(l.x2-l.x1),0.0)
          AS distance,
      ((l.x1-p.px)*SIN(b.angle)-(l.y1-p.py)*COS(b.angle))
        / NULLIF(COS(b.angle)*(l.y2-l.y1)-SIN(b.angle)*(l.x2-l.x1),0.0)
          AS line_u
  ) q
  WHERE q.distance > 0 AND q.distance <= p.max_range AND q.line_u BETWEEN 0 AND 1
    AND (l.right_sector IS NULL OR l.left_sector IS NULL
      OR p.shoot_z+b.slope*q.distance <= l.open_bottom
      OR p.shoot_z+b.slope*q.distance >= l.open_top)
),
nearest_hits AS (
  SELECT * FROM (
    SELECT hits.*,
           ROW_NUMBER() OVER (PARTITION BY pellet ORDER BY distance,
             CASE hit_kind WHEN 'target' THEN 0 ELSE 1 END,
             thing_id, line_id) AS rn
    FROM (
      SELECT * FROM pellet_target_hits
      UNION ALL SELECT * FROM pellet_wall_hits
    ) hits
  ) ranked WHERE rn = 1
),
stored AS (
  INSERT INTO hitscan_hits
    (map_id,player_thing_id,shot_serial,pellet,damage,thing_id,sector_id,
     no_blood,distance,angle,slope,hit_kind,px,py,shoot_z,line_id,line_from_front)
  SELECT p.map_id,p.player_id,p.shot_serial,h.pellet,h.damage,h.thing_id,
         h.sector_id,h.no_blood,h.distance,h.angle,h.slope,h.hit_kind,
         p.px,p.py,p.shoot_z,h.line_id,h.line_from_front
  FROM nearest_hits h CROSS JOIN shooter p
  ON CONFLICT (map_id,player_thing_id,shot_serial,pellet) DO UPDATE
  SET damage=EXCLUDED.damage,thing_id=EXCLUDED.thing_id,
      sector_id=EXCLUDED.sector_id,no_blood=EXCLUDED.no_blood,
      distance=EXCLUDED.distance,angle=EXCLUDED.angle,slope=EXCLUDED.slope,
      hit_kind=EXCLUDED.hit_kind,px=EXCLUDED.px,py=EXCLUDED.py,
      shoot_z=EXCLUDED.shoot_z,line_id=EXCLUDED.line_id,
      line_from_front=EXCLUDED.line_from_front
  RETURNING hit_kind
)
SELECT
  (SELECT count(*) FROM stored WHERE hit_kind='target')::int AS pellets_hit,
  0::int AS monsters_killed,
  (SELECT count(*) FROM stored)::int AS impacts
{ impact_count = impacts; }
return impact_count;
$doom$;
