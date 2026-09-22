CREATE OR REPLACE FUNCTION doom_cs_plan(p_map_id integer, p_player_thing_id integer) RETURNS bigint
LANGUAGE cedarscript AS $doom$
let mut flags = 0::bigint;
let pos_epsilon = doom_const('POS_EPSILON');
let psprite_epsilon = doom_const('PSPRITE_EPSILON');
let psprite_rest_x = doom_const('PSPRITE_REST_X');
let psprite_rest_y = doom_const('PSPRITE_REST_Y');
-- SQL-generated execution plan for the current tic.
WITH input AS (
  SELECT g.*,ps.previous_x,ps.previous_y,ps.position_x,ps.position_y,
         ps.bob_strength,ps.alive,ps.pain_face_tics,
         pw.state AS weapon_state,pw.flash_seq_index,pw.fired_this_tick,
         pw.sx AS weapon_sx,pw.sy AS weapon_sy,
         pw.current_weapon
  FROM game_tic_commands g
  JOIN player_state ps ON ps.map_id=g.map_id
    AND ps.player_thing_id=g.player_thing_id
  JOIN player_weapons pw ON pw.map_id=g.map_id
    AND pw.player_thing_id=g.player_thing_id
  WHERE g.map_id=p_map_id::int AND g.player_thing_id=p_player_thing_id::int
)
SELECT
  i.use_requested,
  -- Any queued event on the map by any actor?
  EXISTS (
    SELECT 1 FROM line_special_events e WHERE e.map_id=i.map_id
  ) AS specials_due,
  (EXISTS (SELECT 1 FROM sector_movers sm
           WHERE sm.map_id=i.map_id AND sm.direction<>2)
   OR EXISTS (SELECT 1 FROM line_buttons b
              WHERE b.map_id=i.map_id AND b.countdown>0)) AS movers_due,
  i.movement_mode,
  (ABS(i.position_x-i.previous_x)>pos_epsilon
   OR ABS(i.position_y-i.previous_y)>pos_epsilon) AS moved,
  (i.attack_held OR i.weapon_switch_to IS NOT NULL
   OR EXISTS (SELECT 1 FROM pickup_grants pg
              WHERE pg.map_id=i.map_id
                AND pg.player_thing_id=i.player_thing_id)
   OR i.weapon_state<>'ready' OR i.flash_seq_index IS NOT NULL
   OR i.bob_strength>psprite_epsilon
   OR ABS(i.weapon_sx-psprite_rest_x)>psprite_epsilon
   OR ABS(i.weapon_sy-psprite_rest_y)>psprite_epsilon
   OR EXISTS (SELECT 1 FROM world_effects we WHERE we.map_id=i.map_id))
    AS weapon_due,
  (i.fired_this_tick AND wd.pellet_count>0) AS hitscan_due,
  (EXISTS (SELECT 1 FROM monster_projectiles mp WHERE mp.map_id=i.map_id)
   OR (i.fired_this_tick AND wd.projectile_type IS NOT NULL)
   OR EXISTS (
     SELECT 1 FROM monster_ai ai
     JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
     JOIN thing_combat_defs d ON d.thing_type=t.type
     WHERE ai.map_id=i.map_id AND ai.fired_this_tick AND d.missile_type IS NOT NULL
   )) AS projectiles_due,
  (i.use_requested OR i.fired_this_tick
   OR EXISTS (SELECT 1 FROM pickup_touches pt
              WHERE pt.map_id=i.map_id
                AND pt.player_thing_id=i.player_thing_id)
   OR EXISTS (SELECT 1 FROM monster_ai ai
              WHERE ai.map_id=i.map_id AND ai.fired_this_tick)
   OR EXISTS (SELECT 1 FROM projectile_impacts pi WHERE pi.map_id=i.map_id)
   OR EXISTS (SELECT 1 FROM sector_movers sm
              WHERE sm.map_id=i.map_id AND sm.direction IN (-1,1))
   OR (wd.idle_loop_sound IS NOT NULL AND i.weapon_state<>'down')
   OR EXISTS (SELECT 1 FROM monster_ai ai
              WHERE ai.map_id=i.map_id AND ai.state <> 'stand')
   OR NOT i.alive
   OR i.pain_face_tics > 0) AS sound_due
FROM input i
JOIN weapon_defs wd ON wd.weapon_id=i.current_weapon
{
  if use_requested { flags = flags + 1; }
  if specials_due { flags = flags + 2; }
  if movers_due { flags = flags + 4; }
  if moved { flags = flags + 8; }
  if weapon_due { flags = flags + 16; }
  if hitscan_due { flags = flags + 32; }
  if projectiles_due { flags = flags + 64; }
  if sound_due { flags = flags + 128; }
}
return flags;
$doom$;
