CREATE OR REPLACE FUNCTION doom_cs_begin(p_map_id integer, p_player_thing_id integer, p_skill integer, p_move_fwd real, p_move_strafe real, p_running boolean, p_turn_degrees real, p_attack_held boolean, p_weapon_switch_to integer, p_use_requested boolean)
LANGUAGE cedarscript AS $doom$
-- Clear the previous tic's transient pickup hand-offs.
DELETE FROM pickup_touches
WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;

DELETE FROM pickup_grants
WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;

-- Latch one client command for an authoritative SQL gameplay tic.
INSERT INTO game_tic_commands
  (map_id,player_thing_id,command_serial,skill,skill_bit,
   move_fwd,move_strafe,running,turn_degrees,attack_held,
   weapon_switch_to,use_requested,movement_mode)
VALUES
  (p_map_id::int,p_player_thing_id::int,1,p_skill::int,
   -- P_SpawnMapThing's own mapping: sk_baby and sk_easy share MTF_EASY,
   -- sk_medium is MTF_NORMAL, sk_hard and sk_nightmare share MTF_HARD.
   CASE WHEN p_skill::int<=1 THEN 1 WHEN p_skill::int=2 THEN 2 ELSE 4 END,
   p_move_fwd::real,p_move_strafe::real,p_running::boolean,p_turn_degrees::real,p_attack_held::boolean,
   p_weapon_switch_to::int,p_use_requested::boolean,'idle')
ON CONFLICT (map_id,player_thing_id) DO UPDATE SET
  command_serial=game_tic_commands.command_serial+1,
  skill=EXCLUDED.skill,
  skill_bit=EXCLUDED.skill_bit,
  move_fwd=EXCLUDED.move_fwd,
  move_strafe=EXCLUDED.move_strafe,
  running=EXCLUDED.running,
  turn_degrees=EXCLUDED.turn_degrees,
  attack_held=EXCLUDED.attack_held,
  weapon_switch_to=EXCLUDED.weapon_switch_to,
  use_requested=EXCLUDED.use_requested,
  movement_mode='idle';
$doom$;
