CREATE OR REPLACE FUNCTION doom_cs_projectiles(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let player_radius = doom_const('PLAYER_RADIUS');
let player_height = doom_const('PLAYER_HEIGHT');
let view_height = doom_const('VIEWHEIGHT');
let missile_spawn_z = doom_const('MISSILE_SPAWN_Z');
let aim_spread = doom_const('AIM_SPREAD_DEGREES');
let shadow_units = doom_const('SHADOW_SPREAD_UNITS');
let effect_id_base = doom_const('PROJECTILE_EFFECT_ID_BASE');
let spawn_ahead = doom_const('MISSILE_SPAWN_AHEAD');
let nightmare_missile_speed = doom_const('NIGHTMARE_MISSILE_SPEED');
let melee_reach = doom_const('MELEE_REACH');
-- Advance every Doom missile.

DELETE FROM projectile_damage WHERE map_id=p_map_id;
DELETE FROM projectile_impacts WHERE map_id=p_map_id;

-- spawn imp fireballs
WITH
params AS (SELECT p_map_id::int AS map_id,p_player_thing_id::int AS player_thing_id),
source AS (
  SELECT ai.thing_id,t.x::double precision AS sx,t.y::double precision AS sy,
         (CASE WHEN d.floats THEN t.z ELSE s.floor_height END
          + missile_spawn_z)::double precision AS sz,
         pt.x::double precision AS tx,pt.y::double precision AS ty,
         (pt.z - (view_height - player_height/2.0))::double precision AS tz,
         COALESCE(ai.sector_id,rt.sector_id) AS sector_id,
         d.missile_type,d.missile_speed,d.missile_dice,pd.dmg_dice_count,
         (d.melee_mult IS NOT NULL) AS has_melee
  FROM monster_ai ai JOIN params p ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type=t.type AND d.missile_type IS NOT NULL
  JOIN projectile_defs pd ON pd.projectile_type=d.missile_type
  JOIN things pt ON pt.map_id=p.map_id AND pt.id=COALESCE(ai.target_thing_id,p.player_thing_id)
  LEFT JOIN render_things rt ON rt.map_id=ai.map_id AND rt.thing_id=ai.thing_id
  JOIN sectors s ON s.map_id=ai.map_id
    AND s.id=COALESCE(ai.sector_id,rt.sector_id)
  WHERE ai.fired_this_tick
    -- in melee range a thing with a bite bites instead (A_TroopAttack and
    -- friends check P_CheckMeleeRange first); one without fires regardless
    AND (NOT d.melee_mult IS NOT NULL OR SQRT(POWER(pt.x-t.x,2)+POWER(pt.y-t.y,2))>melee_reach)
),
-- MF_SHADOW on the target, which for the player means the blur sphere.
shadow AS (
  SELECT (ps.invis_tics > 0) AS shadowed, ps.level_tics
  FROM player_state ps JOIN params p ON ps.map_id=p.map_id
   AND ps.player_thing_id=p.player_thing_id
),
velocity AS (
  -- P_SpawnMissile aims at where the target is, then, if the target carries
  -- MF_SHADOW -- the blur sphere -- throws the shot off by
  -- (P_Random()-P_Random())<<20, which is up to about 22 degrees either way.
  -- Rotating the aim vector is the same thing as skewing the angle.
  SELECT s.*,
         (s.tx-s.sx)*COS(sk.err)-(s.ty-s.sy)*SIN(sk.err) AS dx,
         (s.tx-s.sx)*SIN(sk.err)+(s.ty-s.sy)*COS(sk.err) AS dy,
         (s.tz-s.sz) AS dz,
         SQRT(POWER(s.tx-s.sx,2)+POWER(s.ty-s.sy,2)) AS horizontal_len
  FROM source s
  CROSS JOIN LATERAL (
    SELECT CASE WHEN sh.shadowed
                THEN RADIANS((doom_prandom(s.thing_id, sh.level_tics, 5)
                             -doom_prandom(s.thing_id, sh.level_tics, 6))
                             *360.0/shadow_units)
                ELSE 0.0 END AS err
    FROM shadow sh
  ) sk
),
numbered AS (
  SELECT v.*,(SELECT sh.level_tics FROM shadow sh) AS level_tics,
         ROW_NUMBER() OVER (ORDER BY thing_id) AS rn,
         COALESCE((SELECT MAX(projectile_id) FROM monster_projectiles mp
                   JOIN params p ON mp.map_id=p.map_id),0) AS max_id
  FROM velocity v
)
INSERT INTO monster_projectiles
  (map_id,projectile_id,owner_thing_id,projectile_type,x,y,z,vx,vy,vz,
   sector_id,state,age,damage,impact_player)
SELECT p.map_id,n.max_id+n.rn,n.thing_id,
       n.missile_type,
       n.sx+spawn_ahead*n.dx/NULLIF(n.horizontal_len,0),
       n.sy+spawn_ahead*n.dy/NULLIF(n.horizontal_len,0),n.sz,
       -- BAL7 travels at 15 map units a tic, BAL1 at 10. G_InitNew raises
       -- both to 20 on Nightmare, which is the whole of "fast missiles".
       (CASE WHEN (SELECT g.skill FROM game_tic_commands g
                     WHERE g.map_id=p_map_id::int
                       AND g.player_thing_id=p_player_thing_id::int)=4
              THEN nightmare_missile_speed
              ELSE n.missile_speed END)*n.dx/NULLIF(n.horizontal_len,0),
       (CASE WHEN (SELECT g.skill FROM game_tic_commands g
                     WHERE g.map_id=p_map_id::int
                       AND g.player_thing_id=p_player_thing_id::int)=4
              THEN nightmare_missile_speed
              ELSE n.missile_speed END)*n.dy/NULLIF(n.horizontal_len,0),
       (CASE WHEN (SELECT g.skill FROM game_tic_commands g
                     WHERE g.map_id=p_map_id::int
                       AND g.player_thing_id=p_player_thing_id::int)=4
              THEN nightmare_missile_speed
              ELSE n.missile_speed END)*n.dz/NULLIF(n.horizontal_len,0),
       n.sector_id,'fly',0,
       -- A_TroopAttack rolls 3d8, A_BruisAttack 8d8.
       (n.missile_dice
        *(doom_prandom(n.thing_id, n.level_tics, 7) % n.dmg_dice_count + 1))::smallint,FALSE
FROM numbered n CROSS JOIN params p
WHERE n.horizontal_len>0;

-- spawn player rockets/plasma/BFG
WITH
params AS (SELECT p_map_id::int AS map_id,p_player_thing_id::int AS player_thing_id),
source AS (
  SELECT p.map_id,pw.player_thing_id,t.x::double precision AS sx,
         t.y::double precision AS sy,
         (t.z - (view_height - missile_spawn_z))::double precision AS sz,
         RADIANS(t.angle::double precision) AS angle,
         wd.projectile_type,
         pd.speed::double precision AS speed,
         -- A_FireMissile 20d8, A_FirePlasma 5d8, A_FireBFG 100d8, each keyed
         -- on the shot that fired it and on its own call site.
         pd.dmg_dice_mult
           * (doom_prandom(pw.shot_serial,pw.player_thing_id,pd.dmg_random_id)
              % pd.dmg_dice_count + 1)
           AS damage,
         rt.sector_id
  FROM params p
  -- Every player who fired a launcher this tic
  JOIN player_weapons pw ON pw.map_id=p.map_id
  JOIN weapon_defs wd ON wd.weapon_id=pw.current_weapon
   AND wd.projectile_type IS NOT NULL
  JOIN projectile_defs pd ON pd.projectile_type=wd.projectile_type
  JOIN things t ON t.map_id=pw.map_id AND t.id=pw.player_thing_id
  LEFT JOIN render_things rt ON rt.map_id=t.map_id AND rt.thing_id=t.id
  WHERE pw.fired_this_tick
),
targets AS (
  SELECT s.*,mt.id AS target_id,mt.x::double precision AS tx,
         mt.y::double precision AS ty,
         (sec.floor_height+rt.thing_height/2.0)::double precision AS tz,
         cd.radius::double precision AS radius
  FROM source s
  JOIN thing_health h ON h.map_id=s.map_id AND h.alive
  JOIN things mt ON mt.map_id=h.map_id AND mt.id=h.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=mt.type
  JOIN render_things rt ON rt.map_id=mt.map_id AND rt.thing_id=mt.id
  LEFT JOIN monster_ai ai ON ai.map_id=mt.map_id AND ai.thing_id=mt.id
  JOIN sectors sec ON sec.map_id=mt.map_id
    AND sec.id=COALESCE(ai.sector_id,rt.sector_id)
),
target_geometry AS (
  SELECT t.*,
         (t.tx-t.sx)*COS(t.angle)+(t.ty-t.sy)*SIN(t.angle) AS along,
         -(t.tx-t.sx)*SIN(t.angle)+(t.ty-t.sy)*COS(t.angle) AS lateral_offset
  FROM targets t
),
ranked_targets AS (
  SELECT g.*,ROW_NUMBER() OVER (PARTITION BY map_id,player_thing_id
    ORDER BY ABS(lateral_offset)/NULLIF(along,0),along,target_id) AS rn
  FROM target_geometry g
  WHERE along>0 AND ABS(lateral_offset)<=radius+along*TAN(RADIANS(aim_spread))
),
aimed AS (
  SELECT s.*,r.tz,r.along
  FROM source s LEFT JOIN ranked_targets r
    ON r.map_id=s.map_id AND r.player_thing_id=s.player_thing_id AND r.rn=1
),
numbered AS (
  SELECT a.*,COALESCE((SELECT MAX(projectile_id)
         FROM monster_projectiles mp WHERE mp.map_id=a.map_id),0)
         +ROW_NUMBER() OVER (ORDER BY player_thing_id) AS projectile_id
  FROM aimed a
)
INSERT INTO monster_projectiles
  (map_id,projectile_id,owner_thing_id,projectile_type,x,y,z,vx,vy,vz,
   sector_id,state,age,damage,impact_player)
SELECT map_id,projectile_id,player_thing_id,projectile_type,sx,sy,sz,
       speed*COS(angle),speed*SIN(angle),
       speed*COALESCE((tz-sz)/NULLIF(along,0),0.0),
       sector_id,'fly',0,damage::smallint,FALSE
FROM numbered;

-- swept collision against actors/player/walls
WITH
params AS (SELECT p_map_id::int AS map_id,p_player_thing_id::int AS player_thing_id),
flying AS (
  SELECT mp.*, pd.radius::double precision AS radius
  FROM monster_projectiles mp JOIN params p ON mp.map_id=p.map_id
  JOIN projectile_defs pd ON pd.projectile_type=mp.projectile_type
  WHERE mp.state='fly'
),
players AS (
  -- Every live player is a target for every missile except its own owner's
  SELECT ps.player_thing_id,t.x::double precision AS x,
         t.y::double precision AS y,
         (ps.base_z-view_height)::double precision AS base_z
  FROM player_state ps JOIN params p ON ps.map_id=p.map_id
  JOIN things t ON t.map_id=ps.map_id AND t.id=ps.player_thing_id
  WHERE ps.alive
),
player_hits AS (
  SELECT f.projectile_id,p.player_thing_id,q.t
  FROM flying f JOIN players p ON p.player_thing_id<>f.owner_thing_id
  CROSS JOIN LATERAL (
    SELECT LEAST(1.0,GREATEST(0.0,
      ((p.x-f.x)*f.vx+(p.y-f.y)*f.vy)
       /NULLIF(f.vx*f.vx+f.vy*f.vy,0.0))) AS t
  ) q
  WHERE POWER(f.x+q.t*f.vx-p.x,2)+POWER(f.y+q.t*f.vy-p.y,2)
          <= POWER(f.radius+player_radius,2)
    AND f.z+q.t*f.vz BETWEEN p.base_z AND p.base_z+player_height
),
actor_targets AS (
  SELECT h.map_id,h.thing_id,t.type AS thing_type,t.x::double precision AS x,
         t.y::double precision AS y,cd.radius::double precision AS radius,
         sec.floor_height::double precision AS base_z,
         rt.thing_height::double precision AS height
  FROM thing_health h JOIN params p ON h.map_id=p.map_id AND h.alive
  JOIN things t ON t.map_id=h.map_id AND t.id=h.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=t.type
  JOIN render_things rt ON rt.map_id=t.map_id AND rt.thing_id=t.id
  LEFT JOIN monster_ai ai ON ai.map_id=t.map_id AND ai.thing_id=t.id
  JOIN sectors sec ON sec.map_id=t.map_id
    AND sec.id=COALESCE(ai.sector_id,rt.sector_id)
),
actor_hit_candidates AS (
  SELECT f.projectile_id,t.thing_id,q.t
  FROM flying f JOIN actor_targets t ON t.map_id=f.map_id
  CROSS JOIN LATERAL (
    SELECT LEAST(1.0,GREATEST(0.0,
      ((t.x-f.x)*f.vx+(t.y-f.y)*f.vy)
       /NULLIF(f.vx*f.vx+f.vy*f.vy,0.0))) AS t
  ) q
  -- PIT_CheckThing refuses to damage the shooter's own species: a missile
  -- passing through one of its own kind explodes and does nothing.
  LEFT JOIN things ot ON ot.map_id=f.map_id AND ot.id=f.owner_thing_id
  WHERE (f.projectile_type IN ('rocket','plasma','bfg')
         OR (f.projectile_type IN ('imp_fireball','baron_fireball','caco_fireball')
             AND ot.type IS DISTINCT FROM t.thing_type))
    AND t.thing_id<>f.owner_thing_id
    AND POWER(f.x+q.t*f.vx-t.x,2)+POWER(f.y+q.t*f.vy-t.y,2)
          <= POWER(f.radius+t.radius,2)
    AND f.z+q.t*f.vz BETWEEN t.base_z AND t.base_z+t.height
),
actor_hits AS (
  SELECT projectile_id,thing_id,t FROM (
    SELECT c.*,ROW_NUMBER() OVER
      (PARTITION BY projectile_id ORDER BY t, thing_id) AS rn
    FROM actor_hit_candidates c
  ) r WHERE rn=1
),
wall_hit_candidates AS (
  SELECT f.projectile_id,hit.t
  FROM flying f
  JOIN linedef_geom ld ON ld.map_id=f.map_id
  LEFT JOIN sectors fr ON fr.map_id=ld.map_id AND fr.id=ld.fsec
  LEFT JOIN sectors bk ON bk.map_id=ld.map_id AND bk.id=ld.bsec
  CROSS JOIN LATERAL (
    SELECT f.vx*(ld.y2-ld.y1)-f.vy*(ld.x2-ld.x1) AS denom
  ) d
  CROSS JOIN LATERAL (
    SELECT ((ld.x1-f.x)*(ld.y2-ld.y1)-(ld.y1-f.y)*(ld.x2-ld.x1))
             /NULLIF(d.denom,0.0) AS t,
           ((ld.x1-f.x)*f.vy-(ld.y1-f.y)*f.vx)
             /NULLIF(d.denom,0.0) AS u
  ) hit
  WHERE ABS(d.denom)>1e-9 AND hit.t BETWEEN 0.0 AND 1.0
    AND hit.u BETWEEN 0.0 AND 1.0
    AND (ld.left_sd_id=-1 OR ld.right_sd_id=-1 OR fr.id IS NULL OR bk.id IS NULL
      OR f.z+hit.t*f.vz<=GREATEST(fr.floor_height,bk.floor_height)
      OR f.z+hit.t*f.vz>=LEAST(fr.ceil_height,bk.ceil_height))
),
wall_hits AS (
  SELECT projectile_id,MIN(t) AS t FROM wall_hit_candidates GROUP BY projectile_id
),
candidates AS (
  SELECT projectile_id,t,TRUE AS target_player,player_thing_id AS target_thing_id,0 AS priority
    FROM player_hits
  UNION ALL SELECT projectile_id,t,FALSE,thing_id,0 FROM actor_hits
  UNION ALL SELECT projectile_id,t,FALSE,NULL::int,1 FROM wall_hits
),
nearest AS (
  SELECT * FROM (
    SELECT c.*,ROW_NUMBER() OVER
      (PARTITION BY projectile_id ORDER BY t,priority,
       COALESCE(target_thing_id,-1)) AS rn
    FROM candidates c
  ) r WHERE rn=1
)
INSERT INTO projectile_impacts
  (map_id,projectile_id,projectile_type,owner_thing_id,x,y,z,
   target_player,target_thing_id,target_player_thing_id)
SELECT f.map_id,f.projectile_id,f.projectile_type,f.owner_thing_id,
       f.x+n.t*f.vx,f.y+n.t*f.vy,f.z+n.t*f.vz,
       n.target_player,n.target_thing_id,
       CASE WHEN n.target_player THEN n.target_thing_id END
FROM nearest n JOIN flying f ON f.projectile_id=n.projectile_id;

-- direct player-projectile damage
INSERT INTO projectile_damage
  (map_id,projectile_id,damage_kind,hit_index,thing_id,damage)
SELECT i.map_id,i.projectile_id,'direct',-1,i.target_thing_id,mp.damage
FROM projectile_impacts i
JOIN monster_projectiles mp ON mp.map_id=i.map_id
  AND mp.projectile_id=i.projectile_id
WHERE i.map_id=p_map_id::int
  AND i.target_thing_id IS NOT NULL
  AND i.projectile_type IN ('rocket','plasma','bfg',
                            'imp_fireball','baron_fireball','caco_fireball');

-- rocket radius damage
WITH
params AS (SELECT p_map_id::int AS map_id),
-- Anything the catalogue gives a blast radius; only the rocket has one.
explosions AS (
  SELECT i.* FROM projectile_impacts i JOIN params p ON i.map_id=p.map_id
  JOIN projectile_defs pd ON pd.projectile_type=i.projectile_type
   AND pd.blast_radius IS NOT NULL
),
victims AS (
  SELECT h.map_id,h.thing_id,t.x::double precision AS x,t.y::double precision AS y,
         cd.radius::double precision AS radius
  FROM thing_health h JOIN params p ON h.map_id=p.map_id AND h.alive
  JOIN things t ON t.map_id=h.map_id AND t.id=h.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=t.type
  UNION ALL
  -- P_RadiusAttack spares nobody, the shooter included.
  SELECT ps.map_id,ps.player_thing_id,t.x::double precision,t.y::double precision,
         player_radius::double precision
  FROM player_state ps JOIN params p ON ps.map_id=p.map_id
  JOIN things t ON t.map_id=ps.map_id AND t.id=ps.player_thing_id
  WHERE ps.alive
),
blocking AS (
  SELECT ld.x1::double precision AS x1,ld.y1::double precision AS y1,
         ld.x2::double precision AS x2,ld.y2::double precision AS y2
  FROM linedef_geom ld JOIN params p ON ld.map_id=p.map_id
  LEFT JOIN sectors fr ON fr.map_id=ld.map_id AND fr.id=ld.fsec
  LEFT JOIN sectors bk ON bk.map_id=ld.map_id AND bk.id=ld.bsec
  WHERE ld.left_sd_id=-1 OR ld.right_sd_id=-1 OR fr.id IS NULL OR bk.id IS NULL
     OR LEAST(fr.ceil_height,bk.ceil_height)<=GREATEST(fr.floor_height,bk.floor_height)
),
radial AS (
  SELECT e.map_id,e.projectile_id,v.thing_id,
         GREATEST(0,pd.blast_radius-GREATEST(0,
           FLOOR(GREATEST(ABS(v.x-e.x),ABS(v.y-e.y))-v.radius)::int)) AS damage
  FROM explosions e CROSS JOIN victims v
  JOIN projectile_defs pd ON pd.projectile_type=e.projectile_type
   AND pd.blast_radius IS NOT NULL
  WHERE GREATEST(ABS(v.x-e.x),ABS(v.y-e.y))-v.radius<pd.blast_radius
    AND NOT EXISTS (
      SELECT 1 FROM blocking b CROSS JOIN LATERAL (
        SELECT (e.x-b.x1)*(b.y2-b.y1)-(e.y-b.y1)*(b.x2-b.x1) AS d1,
               (v.x-b.x1)*(b.y2-b.y1)-(v.y-b.y1)*(b.x2-b.x1) AS d2,
               (b.x1-e.x)*(v.y-e.y)-(b.y1-e.y)*(v.x-e.x) AS d3,
               (b.x2-e.x)*(v.y-e.y)-(b.y2-e.y)*(v.x-e.x) AS d4
      ) q WHERE q.d1*q.d2<0 AND q.d3*q.d4<0
    )
)
INSERT INTO projectile_damage
  (map_id,projectile_id,damage_kind,hit_index,thing_id,damage)
SELECT map_id,projectile_id,'splash',thing_id,thing_id,damage
FROM radial WHERE damage>0;

-- BFG spray, 40 rays across 90 degrees
WITH
params AS (SELECT p_map_id::int AS map_id),
bfg AS (
  SELECT mp.*,t.x::double precision AS ox,t.y::double precision AS oy,
         pd.spray_rays,pd.spray_arc_degrees,pd.spray_range,
         pd.spray_dice,pd.spray_random_base,pd.dmg_dice_count
  FROM monster_projectiles mp JOIN params p ON mp.map_id=p.map_id
  JOIN things t ON t.map_id=mp.map_id AND t.id=mp.owner_thing_id
  JOIN projectile_defs pd ON pd.projectile_type=mp.projectile_type
  WHERE mp.state='explode' AND pd.spray_at_tic IS NOT NULL
    AND mp.age=pd.spray_at_tic
),
-- A_BFGSpray fans spray_rays evenly across spray_arc_degrees, centred on the
-- ball's own heading.
rays AS (
  SELECT b.*,r.i AS ray_index,
         ATAN2(b.vy,b.vx)
           + RADIANS(-b.spray_arc_degrees/2.0
                     + (b.spray_arc_degrees/b.spray_rays)*r.i) AS ray_angle
  FROM bfg b CROSS JOIN LATERAL generate_series(0,b.spray_rays-1) r(i)
),
targets AS (
  SELECT h.map_id,h.thing_id,t.x::double precision AS x,t.y::double precision AS y,
         cd.radius::double precision AS radius
  FROM thing_health h JOIN params p ON h.map_id=p.map_id AND h.alive
  JOIN things t ON t.map_id=h.map_id AND t.id=h.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=t.type
  UNION ALL
  -- The spray reaches players too; the shooter is excluded below.
  SELECT ps.map_id,ps.player_thing_id,t.x::double precision,t.y::double precision,
         player_radius::double precision
  FROM player_state ps JOIN params p ON ps.map_id=p.map_id
  JOIN things t ON t.map_id=ps.map_id AND t.id=ps.player_thing_id
  WHERE ps.alive
),
blocking AS (
  SELECT ld.x1::double precision AS x1,ld.y1::double precision AS y1,
         ld.x2::double precision AS x2,ld.y2::double precision AS y2
  FROM linedef_geom ld JOIN params p ON ld.map_id=p.map_id
  LEFT JOIN sectors fr ON fr.map_id=ld.map_id AND fr.id=ld.fsec
  LEFT JOIN sectors bk ON bk.map_id=ld.map_id AND bk.id=ld.bsec
  WHERE ld.left_sd_id=-1 OR ld.right_sd_id=-1 OR fr.id IS NULL OR bk.id IS NULL
     OR LEAST(fr.ceil_height,bk.ceil_height)<=GREATEST(fr.floor_height,bk.floor_height)
),
intersections AS (
  SELECT r.map_id,r.projectile_id,r.ray_index,t.thing_id,
         r.ox,r.oy,t.x,t.y,r.spray_range,r.spray_dice,r.spray_random_base,
         r.dmg_dice_count,
         g.along-SQRT(GREATEST(0.0,t.radius*t.radius-g.perp2)) AS distance
  FROM rays r CROSS JOIN targets t
  CROSS JOIN LATERAL (
    SELECT (t.x-r.ox)*COS(r.ray_angle)+(t.y-r.oy)*SIN(r.ray_angle) AS along,
           POWER(-(t.x-r.ox)*SIN(r.ray_angle)+(t.y-r.oy)*COS(r.ray_angle),2) AS perp2
  ) g
  WHERE t.thing_id<>r.owner_thing_id AND g.along>0
    AND g.along<=r.spray_range+t.radius
    AND g.perp2<=t.radius*t.radius
),
visible AS (
  SELECT i.* FROM intersections i
  WHERE i.distance>0 AND i.distance<=i.spray_range
    AND NOT EXISTS (
      SELECT 1 FROM blocking b CROSS JOIN LATERAL (
        SELECT (i.ox-b.x1)*(b.y2-b.y1)-(i.oy-b.y1)*(b.x2-b.x1) AS d1,
               (i.x-b.x1)*(b.y2-b.y1)-(i.y-b.y1)*(b.x2-b.x1) AS d2,
               (b.x1-i.ox)*(i.y-i.oy)-(b.y1-i.oy)*(i.x-i.ox) AS d3,
               (b.x2-i.ox)*(i.y-i.oy)-(b.y2-i.oy)*(i.x-i.ox) AS d4
      ) q WHERE q.d1*q.d2<0 AND q.d3*q.d4<0
    )
),
ranked AS (
  SELECT i.*,ROW_NUMBER() OVER (PARTITION BY projectile_id,ray_index
                               ORDER BY distance, thing_id) AS rn
  FROM visible i
),
hits AS (SELECT * FROM ranked WHERE rn=1)
INSERT INTO projectile_damage
  (map_id,projectile_id,damage_kind,hit_index,thing_id,damage)
SELECT h.map_id,h.projectile_id,'bfg_spray',h.ray_index,h.thing_id,
       -- A_BFGSpray rolls 15d8 per ray
       (SELECT SUM(doom_prandom(h.thing_id, h.projectile_id*64 + h.ray_index,
                               h.spray_random_base + g.i) % h.dmg_dice_count + 1)
       FROM generate_series(0, h.spray_dice - 1) g(i))
FROM hits h;

-- apply accumulated actor damage
UPDATE thing_health h
SET health=h.health-d.damage,alive=h.health-d.damage>0
FROM (
  SELECT map_id,thing_id,SUM(damage)::int AS damage
  FROM projectile_damage WHERE map_id=p_map_id GROUP BY map_id,thing_id
) d
WHERE h.map_id=d.map_id AND h.thing_id=d.thing_id;

--P_DamageMobj's thrust
UPDATE things t
SET mom_x = (t.mom_x + s.ddx)::real,
    mom_y = (t.mom_y + s.ddy)::real
FROM (
  SELECT q.thing_id,
         SUM(ROUND(q.push * q.dx / q.dist * 65536)) / 65536.0 AS ddx,
         SUM(ROUND(q.push * q.dy / q.dist * 65536)) / 65536.0 AS ddy
  FROM (
    SELECT pd.thing_id,
           pd.damage * 12.5 / GREATEST(1, cd.mass) AS push,
           (v.x - src.x)::float8 AS dx, (v.y - src.y)::float8 AS dy,
           NULLIF(SQRT(POWER(v.x-src.x,2)+POWER(v.y-src.y,2)),0)::float8 AS dist
    FROM projectile_damage pd
    JOIN things v ON v.map_id=pd.map_id AND v.id=pd.thing_id
    JOIN thing_combat_defs cd ON cd.thing_type=v.type
    CROSS JOIN LATERAL (
      SELECT CASE WHEN pd.damage_kind='bfg_spray' THEN pl.x ELSE i.x END AS x,
             CASE WHEN pd.damage_kind='bfg_spray' THEN pl.y ELSE i.y END AS y
      FROM things pl
      LEFT JOIN projectile_impacts i ON i.map_id=pd.map_id
       AND i.projectile_id=pd.projectile_id
      WHERE pl.map_id=pd.map_id AND pl.id=p_player_thing_id::int
    ) src
    WHERE pd.map_id=p_map_id AND pd.damage>0
      AND NOT EXISTS (SELECT 1 FROM player_state ps
                      WHERE ps.map_id=pd.map_id AND ps.player_thing_id=pd.thing_id)
  ) q
  WHERE q.dist IS NOT NULL
  GROUP BY q.thing_id
) s
WHERE t.map_id=p_map_id AND t.id=s.thing_id;

-- a hurt monster turns on whatever hit it
UPDATE monster_ai ai
SET target_thing_id = src.owner_thing_id,
    state = CASE WHEN ai.state = 'stand' THEN 'see'::actor_state ELSE ai.state END,
    seq_index = CASE WHEN ai.state = 'stand' THEN 0 ELSE ai.seq_index END,
    state_tics = CASE WHEN ai.state = 'stand' THEN 0 ELSE ai.state_tics END
FROM (
  SELECT d.thing_id, ARG_MAX(i.owner_thing_id, i.projectile_id) AS owner_thing_id
  FROM projectile_damage d
  JOIN projectile_impacts i ON i.map_id = d.map_id
   AND i.projectile_id = d.projectile_id
  WHERE d.map_id = p_map_id
    AND (i.projectile_type IN ('imp_fireball','baron_fireball','caco_fireball')
         OR EXISTS (SELECT 1 FROM monster_ai mo WHERE mo.map_id=i.map_id AND mo.thing_id=i.owner_thing_id))
    AND i.owner_thing_id IS NOT NULL
  GROUP BY d.thing_id
) src
WHERE ai.map_id = p_map_id AND ai.thing_id = src.thing_id
  AND ai.thing_id <> src.owner_thing_id
  AND ai.target_thing_id IS DISTINCT FROM src.owner_thing_id;

-- put surviving hit actors into pain
WITH pain_rolls AS (
  SELECT d.map_id,d.thing_id,
         BOOL_OR(doom_prandom(d.thing_id, d.projectile_id, 11)
                   < cd.pain_chance) AS flinches,
         t.type
  FROM projectile_damage d
  JOIN things t ON t.map_id=d.map_id AND t.id=d.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=t.type
  WHERE d.map_id=p_map_id AND d.damage>0
  GROUP BY d.map_id,d.thing_id,t.type
)
UPDATE monster_ai ai
SET state=CASE WHEN hit.flinches THEN 'pain' ELSE 'see' END,
    seq_index=CASE WHEN hit.flinches THEN 0 ELSE ai.seq_index END,
    state_tics=CASE WHEN hit.flinches THEN COALESCE(fp.tics,ai.state_tics)
                    ELSE COALESCE(fs.tics,ai.state_tics) END
FROM pain_rolls hit
JOIN thing_health h ON h.map_id=hit.map_id AND h.thing_id=hit.thing_id
LEFT JOIN thing_ai_frames fp ON fp.thing_type=hit.type
  AND fp.state='pain' AND fp.seq_index=0
LEFT JOIN thing_ai_frames fs ON fs.thing_type=hit.type
  AND fs.state='see' AND fs.seq_index=0
WHERE ai.map_id=hit.map_id AND ai.thing_id=hit.thing_id
  AND h.alive AND ai.state NOT IN ('die','dead')
  AND NOT EXISTS (SELECT 1 FROM thing_combat_defs bd
                  WHERE bd.thing_type = hit.type AND bd.explodes)
  AND (hit.flinches OR ai.state='stand');

-- visible BFG spray explosions
INSERT INTO world_effects
  (map_id,effect_id,effect_type,x,y,z,sector_id,age)
SELECT d.map_id,effect_id_base::bigint+d.projectile_id*100+d.hit_index,
       'bfg_spray',t.x,t.y,sec.floor_height+rt.thing_height/4.0,
       COALESCE(ai.sector_id,rt.sector_id),0
FROM projectile_damage d
JOIN things t ON t.map_id=d.map_id AND t.id=d.thing_id
JOIN render_things rt ON rt.map_id=t.map_id AND rt.thing_id=t.id
LEFT JOIN monster_ai ai ON ai.map_id=t.map_id AND ai.thing_id=t.id
JOIN sectors sec ON sec.map_id=t.map_id
  AND sec.id=COALESCE(ai.sector_id,rt.sector_id)
WHERE d.map_id=p_map_id AND d.damage_kind='bfg_spray'
ON CONFLICT (map_id,effect_id) DO NOTHING;

-- projectile damage landing on players
WITH
params AS (SELECT p_map_id::int AS map_id),
landed AS (
  SELECT pd.thing_id AS victim_id, pd.damage,
         CASE WHEN pd.damage_kind='bfg_spray' THEN ot.x ELSE i.x END::float8 AS ix,
         CASE WHEN pd.damage_kind='bfg_spray' THEN ot.y ELSE i.y END::float8 AS iy,
         COALESCE(k.player_thing_id, -1) AS source_id
  FROM projectile_damage pd
  JOIN params p ON pd.map_id=p.map_id
  JOIN player_state v ON v.map_id=pd.map_id AND v.player_thing_id=pd.thing_id
  JOIN monster_projectiles mp ON mp.map_id=pd.map_id AND mp.projectile_id=pd.projectile_id
  LEFT JOIN projectile_impacts i ON i.map_id=pd.map_id AND i.projectile_id=pd.projectile_id
  LEFT JOIN things ot ON ot.map_id=mp.map_id AND ot.id=mp.owner_thing_id
  LEFT JOIN player_state k ON k.map_id=mp.map_id AND k.player_thing_id=mp.owner_thing_id
  WHERE pd.damage>0
),
scaled AS (
  SELECT l.victim_id,
         l.damage >> CASE WHEN g.skill=0 THEN 1 ELSE 0 END AS dmg,
         l.ix,l.iy,l.source_id,
         vt.x::float8 AS vx,vt.y::float8 AS vy
  FROM landed l
  JOIN player_state v ON v.map_id=p_map_id::int AND v.player_thing_id=l.victim_id
  JOIN game_tic_commands g ON g.map_id=v.map_id AND g.player_thing_id=v.player_thing_id
  JOIN things vt ON vt.map_id=v.map_id AND vt.id=v.player_thing_id
),
totals AS (
  SELECT victim_id,
         SUM(dmg)::int AS dmg,
         SUM(FLOOR(dmg/3.0))::int AS green_saved,
         SUM(FLOOR(dmg/2.0))::int AS blue_saved,
         ARG_MAX(source_id, dmg::bigint*1000000 + source_id) AS source_id,
         -- Summed in 16.16 fixed point, as vanilla adds momentum: a float sum
         -- of several hits depends on the order the rows arrive in.
         SUM(ROUND(CASE WHEN r.dist>0 THEN dmg*0.125*(vx-ix)/r.dist ELSE 0.0 END * 65536.0)) / 65536.0 AS thrust_x,
         SUM(ROUND(CASE WHEN r.dist>0 THEN dmg*0.125*(vy-iy)/r.dist ELSE 0.0 END * 65536.0)) / 65536.0 AS thrust_y
  FROM scaled s
  CROSS JOIN LATERAL (SELECT SQRT(POWER(s.vx-s.ix,2)+POWER(s.vy-s.iy,2)) AS dist) r
  GROUP BY victim_id
),
absorbed AS (
  SELECT t.*,
         (ps.god_mode OR ps.invuln_tics>0) AS blocked,
         CASE WHEN ps.god_mode OR ps.invuln_tics>0 THEN 0
              ELSE LEAST(ps.armor,CASE ps.armor_class
                     WHEN 2 THEN t.blue_saved WHEN 1 THEN t.green_saved
                     ELSE 0 END)
         END AS saved
  FROM totals t
  JOIN player_state ps ON ps.map_id=p_map_id::int AND ps.player_thing_id=t.victim_id
),
applied AS (
  SELECT a.*,CASE WHEN a.blocked THEN 0 ELSE a.dmg-a.saved END AS took
  FROM absorbed a
)
UPDATE player_state ps
SET armor=ps.armor-a.saved,
    armor_class=CASE WHEN ps.armor-a.saved<=0 THEN 0 ELSE ps.armor_class END,
    health=GREATEST(0,ps.health-a.took),
    damage_count=LEAST(100,ps.damage_count+a.took),
    alive=GREATEST(0,ps.health-a.took)>0,
    pain_face_tics=CASE WHEN a.took>0 THEN 12 ELSE ps.pain_face_tics END,
    killer_id=CASE WHEN ps.alive AND ps.health-a.took<=0 THEN a.source_id
                   ELSE ps.killer_id END,
    momentum_x=(ps.momentum_x+a.thrust_x)::real,
    momentum_y=(ps.momentum_y+a.thrust_y)::real
FROM applied a
WHERE ps.map_id=p_map_id::int AND ps.player_thing_id=a.victim_id;

-- enter impact state
UPDATE monster_projectiles mp
SET x=i.x,y=i.y,z=i.z,state='explode',age=0,
    impact_player=i.target_player
FROM projectile_impacts i
WHERE mp.map_id=p_map_id AND i.map_id=mp.map_id
  AND i.projectile_id=mp.projectile_id AND mp.state='fly';

-- advance unobstructed flights
UPDATE monster_projectiles mp
SET x=mp.x+mp.vx,y=mp.y+mp.vy,z=mp.z+mp.vz,
    age=mp.age+1,impact_player=FALSE
WHERE mp.map_id=p_map_id AND mp.state='fly'
  AND NOT EXISTS (
    SELECT 1 FROM projectile_impacts i
    WHERE i.map_id=mp.map_id AND i.projectile_id=mp.projectile_id
  );

-- advance explosion animations
UPDATE monster_projectiles
SET age=age+1,impact_player=FALSE
WHERE map_id=p_map_id AND state='explode';

-- retire completed missiles
-- Retire a missile when its explosion animation has run out, or when one
-- that never hit anything has been in the air too long.
DELETE FROM monster_projectiles mp
USING projectile_defs pd
WHERE mp.map_id=p_map_id AND pd.projectile_type=mp.projectile_type
  AND ((mp.state='explode' AND mp.age>=pd.explode_tics)
    OR (mp.state='fly' AND mp.age>=pd.fly_timeout));
$doom$;
