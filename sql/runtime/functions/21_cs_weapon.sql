CREATE OR REPLACE FUNCTION doom_cs_weapon(p_map_id integer, p_player_thing_id integer) RETURNS bigint
LANGUAGE cedarscript AS $doom$
doom_cs_weapon_state(p_map_id,p_player_thing_id);
-- Deduct ammo for just fired shots
UPDATE player_state ps
SET ammo_bullets = ps.ammo_bullets
      - CASE WHEN pw.fired_this_tick AND wd.ammo_type = 'bullets' THEN wd.ammo_per_shot ELSE 0 END,
    ammo_shells = ps.ammo_shells
      - CASE WHEN pw.fired_this_tick AND wd.ammo_type = 'shells' THEN wd.ammo_per_shot ELSE 0 END,
    ammo_rockets = ps.ammo_rockets
      - CASE WHEN pw.fired_this_tick AND wd.ammo_type = 'rockets' THEN wd.ammo_per_shot ELSE 0 END,
    ammo_cells = ps.ammo_cells
      - CASE WHEN pw.fired_this_tick AND wd.ammo_type = 'cells' THEN wd.ammo_per_shot ELSE 0 END
FROM player_weapons pw
JOIN weapon_defs wd ON wd.weapon_id = pw.current_weapon
WHERE ps.map_id = pw.map_id AND ps.player_thing_id = pw.player_thing_id
  AND pw.map_id = p_map_id AND pw.player_thing_id = p_player_thing_id;

UPDATE world_effects
SET age=age+1
WHERE map_id=p_map_id;

DELETE FROM world_effects
WHERE map_id=p_map_id
  AND age>=CASE WHEN effect_type='blood' THEN 24
                WHEN effect_type='bfg_spray' THEN 32
                WHEN effect_type='ifog' THEN 30
                WHEN effect_type='tfog' THEN 72 ELSE 16 END;
let mut result_shot = 0::bigint;
SELECT pw.state, pw.seq_index, pw.flash_seq_index, pw.flash_tics,
       pw.sx, pw.sy, pw.shot_serial, pw.fired_this_tick, pw.current_weapon,
       wd.pellet_count, wd.max_range, wd.dmg_dice_count, wd.dmg_dice_mult,
       (SELECT count(*) FROM world_effects WHERE map_id = p_map_id)::int AS effects_alive
FROM player_weapons pw
JOIN weapon_defs wd ON wd.weapon_id = pw.current_weapon
WHERE pw.map_id = p_map_id AND pw.player_thing_id = p_player_thing_id
{ result_shot = shot_serial; }
return result_shot;
$doom$;
