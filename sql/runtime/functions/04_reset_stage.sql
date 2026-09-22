CREATE OR REPLACE FUNCTION doom_reset_stage(p_map_id integer, p_skill integer)
LANGUAGE cedarscript AS $doom$
-- Restore a stage's mutable sector geometry and clear its thinkers.
UPDATE sectors
SET floor_height = spawn_floor_height,
    ceil_height = spawn_ceil_height,
    floor_tex = spawn_floor_tex,
    light_level = COALESCE(spawn_light_level, light_level)
WHERE map_id = p_map_id;

DELETE FROM sector_light_fx WHERE map_id = p_map_id;

INSERT INTO sector_light_fx (map_id, sector_id, special, base_light, dark_light)
SELECT s.map_id, s.id, s.special::smallint,
       COALESCE(s.spawn_light_level, s.light_level)::smallint,
       LEAST(COALESCE(s.spawn_light_level, s.light_level),
             COALESCE(MIN(other.light_level), 0::smallint))::smallint
FROM sectors s
LEFT JOIN linedefs edge ON edge.map_id = s.map_id
LEFT JOIN sidedefs r ON r.map_id = edge.map_id AND r.id = edge.right_sd_id
LEFT JOIN sidedefs l ON l.map_id = edge.map_id AND l.id = edge.left_sd_id
LEFT JOIN sectors other ON other.map_id = s.map_id
  AND other.id = CASE WHEN r.sector_id = s.id THEN l.sector_id
                      WHEN l.sector_id = s.id THEN r.sector_id END
WHERE s.map_id = p_map_id AND s.special IN (1,2,3,8,12,13,17)
GROUP BY s.map_id, s.id, s.special, s.spawn_light_level, s.light_level;

UPDATE render_segs rs
SET f_floor = s.floor_height, f_ceil = s.ceil_height,
    f_ceil_tex = s.ceil_tex, f_light = s.light_level
FROM sectors s
WHERE rs.map_id = p_map_id AND s.map_id = rs.map_id
  AND rs.fsec = s.id
  AND (rs.f_floor <> s.floor_height OR rs.f_ceil <> s.ceil_height
    OR rs.f_ceil_tex IS DISTINCT FROM s.ceil_tex OR rs.f_light <> s.light_level);

UPDATE render_segs rs
SET b_floor = s.floor_height, b_ceil = s.ceil_height,
    b_ceil_tex = s.ceil_tex, b_light = s.light_level
FROM sectors s
WHERE rs.map_id = p_map_id AND s.map_id = rs.map_id
  AND rs.bsec = s.id
  AND (rs.b_floor <> s.floor_height OR rs.b_ceil <> s.ceil_height
    OR rs.b_ceil_tex IS DISTINCT FROM s.ceil_tex OR rs.b_light <> s.light_level);

DELETE FROM sector_movers WHERE map_id = p_map_id;

-- Restore any switch/button textures before clearing their runtime rows.
WITH original AS (
  SELECT DISTINCT map_id,sidedef_id FROM line_buttons WHERE map_id=p_map_id
)
UPDATE sidedefs sd
SET upper_tex=COALESCE(u.original_tex,sd.upper_tex),
    mid_tex=COALESCE(m.original_tex,sd.mid_tex),
    lower_tex=COALESCE(l.original_tex,sd.lower_tex)
FROM original o
LEFT JOIN line_buttons u ON u.map_id=o.map_id AND u.sidedef_id=o.sidedef_id
  AND u.texture_part='upper'
LEFT JOIN line_buttons m ON m.map_id=o.map_id AND m.sidedef_id=o.sidedef_id
  AND m.texture_part='middle'
LEFT JOIN line_buttons l ON l.map_id=o.map_id AND l.sidedef_id=o.sidedef_id
  AND l.texture_part='lower'
WHERE sd.map_id=o.map_id AND sd.id=o.sidedef_id;

UPDATE render_segs rs
SET upper_tex=sd.upper_tex, mid_tex=sd.mid_tex, lower_tex=sd.lower_tex,
    x_offset=sd.x_offset,y_offset=sd.y_offset
FROM linedefs ld,sidedefs sd
WHERE rs.map_id=p_map_id AND ld.map_id=rs.map_id AND ld.id=rs.linedef_id
  AND sd.map_id=ld.map_id
  AND sd.id=CASE WHEN rs.direction=0 THEN ld.right_sd_id ELSE ld.left_sd_id END;

DELETE FROM line_buttons WHERE map_id = p_map_id;

DELETE FROM line_activations WHERE map_id = p_map_id;

DELETE FROM line_special_events WHERE map_id = p_map_id;

DELETE FROM line_use_results WHERE map_id = p_map_id;

DELETE FROM pickup_grants WHERE map_id = p_map_id;

DELETE FROM sound_events WHERE map_id = p_map_id;

DELETE FROM mapped_lines WHERE map_id = p_map_id;

-- Dropped items from monster deaths are transient
-- they only ever existed this playthrough, so they don't get a spawn_x/y
-- to restore like real WAD Things, so just remove them outright.
-- They are fortunately easy to recognize (source_thing_id + 100000)
DELETE FROM render_things WHERE map_id = p_map_id AND thing_id >= 100000;

DELETE FROM things WHERE map_id = p_map_id AND id >= 100000;

-- Move monsters back to their spawn
UPDATE things
SET x = spawn_x, y = spawn_y, angle = spawn_angle,
    mom_x = 0, mom_y = 0
WHERE map_id = p_map_id;

UPDATE render_things
SET sector_id = spawn_sector_id
WHERE map_id = p_map_id AND spawn_sector_id IS NOT NULL AND sector_id <> spawn_sector_id;

-- Floaters keep their height in z
UPDATE things t
SET z = s.floor_height
FROM render_things rt
JOIN sectors s ON s.map_id = rt.map_id AND s.id = rt.sector_id
JOIN thing_combat_defs d ON d.thing_type = t.type AND d.floats
WHERE t.map_id = p_map_id
  AND rt.map_id = t.map_id AND rt.thing_id = t.id;

DELETE FROM thing_health WHERE map_id = p_map_id;

DELETE FROM monster_deaths WHERE map_id = p_map_id;
DELETE FROM monster_steps WHERE map_id = p_map_id;
DELETE FROM automap_view WHERE map_id = p_map_id;
DELETE FROM monster_attack_damage WHERE map_id = p_map_id;
DELETE FROM monster_teleports WHERE map_id = p_map_id;

INSERT INTO thing_health (map_id, thing_id, health, max_health, alive)
SELECT t.map_id, t.id, d.spawn_health, d.spawn_health, TRUE
FROM things t
JOIN thing_combat_defs d ON d.thing_type = t.type
CROSS JOIN (SELECT CASE WHEN p_skill<=1 THEN 1
                        WHEN p_skill=2 THEN 2 ELSE 4 END AS bit) spawn
WHERE t.map_id = p_map_id AND (t.flags & spawn.bit) <> 0
  AND (t.flags & 16) = 0;

DELETE FROM monster_ai WHERE map_id = p_map_id;

INSERT INTO monster_ai (map_id, thing_id, state, state_tics, seq_index,
                         sector_id, attack_cooldown, fired_this_tick)
SELECT map_id, thing_id, 'stand', -1, 0, NULL, 0, FALSE
FROM thing_health WHERE map_id = p_map_id;

DELETE FROM player_weapons WHERE map_id = p_map_id;

INSERT INTO player_weapons (map_id, player_thing_id)
SELECT t.map_id, t.id FROM things t
JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
WHERE t.map_id = p_map_id;

-- Vanilla starts every player with the fist and pistol (weapon_id 1, 2).
DELETE FROM player_weapon_owned WHERE map_id = p_map_id;

INSERT INTO player_weapon_owned (map_id, player_thing_id, weapon_id)
SELECT t.map_id, t.id, w.weapon_id
FROM things t CROSS JOIN (VALUES (1), (2)) AS w (weapon_id)
JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
WHERE t.map_id = p_map_id;

DELETE FROM player_state WHERE map_id = p_map_id;

-- 50 starting bullets
INSERT INTO player_state (
  map_id,player_thing_id,health,alive,ammo_bullets,
  previous_x,previous_y,position_x,position_y,base_z,view_z,view_angle
)
SELECT t.map_id,t.id,100,TRUE,50,t.x,t.y,t.x,t.y,t.z,t.z,t.angle
FROM things t
JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
WHERE t.map_id = p_map_id;

DELETE FROM world_effects WHERE map_id = p_map_id;

DELETE FROM monster_projectiles WHERE map_id = p_map_id;

DELETE FROM projectile_impacts WHERE map_id = p_map_id;

DELETE FROM projectile_damage WHERE map_id = p_map_id;

DELETE FROM hitscan_hits WHERE map_id = p_map_id;

DELETE FROM picked_up_items WHERE map_id = p_map_id;

DELETE FROM item_respawns WHERE map_id = p_map_id;

DELETE FROM pickup_touches WHERE map_id = p_map_id;

DELETE FROM game_tic_commands WHERE map_id = p_map_id;

-- Start a fresh intermission record.
DELETE FROM level_secret_discoveries WHERE map_id = p_map_id;

DELETE FROM level_stats WHERE map_id = p_map_id;

WITH params AS (
  SELECT p_map_id::int AS map_id,
         CASE WHEN p_skill<=1 THEN 1
              WHEN p_skill=2 THEN 2 ELSE 4 END AS skill_bit
)
INSERT INTO level_stats (
  map_id,player_thing_id,skill_bit,par_tics,
  total_kills,total_items,total_secrets
)
SELECT
  t.map_id,t.id,p.skill_bit,
  (SELECT lp.par_secs*35 FROM level_pars lp
    WHERE lp.episode = substring(m.name FROM 2 FOR 1)::int
      AND lp.level   = substring(m.name FROM 4 FOR 1)::int),
  (SELECT count(*)
   FROM things mt
   JOIN thing_combat_defs cd ON cd.thing_type=mt.type AND cd.counts_kill
   WHERE mt.map_id=p.map_id
     AND (mt.flags & p.skill_bit)<>0 AND (mt.flags & 16)=0),
  (SELECT count(*)
   FROM things it
   WHERE it.map_id=p.map_id
     AND (it.flags & p.skill_bit)<>0 AND (it.flags & 16)=0
     AND EXISTS (
       SELECT 1 FROM pickup_defs pd
       WHERE pd.thing_type=it.type AND pd.counts_item
     )),
  (SELECT count(*) FROM sectors s
   JOIN sector_special_defs sd ON sd.special=s.special AND sd.is_secret
   WHERE s.map_id=p.map_id)
FROM params p
JOIN things t ON t.map_id=p.map_id
JOIN thing_role_defs r ON r.thing_type=t.type AND r.player_number=1
JOIN maps m ON m.map_id=t.map_id;
$doom$;
