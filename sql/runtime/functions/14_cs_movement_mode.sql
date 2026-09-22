CREATE OR REPLACE FUNCTION doom_cs_movement_mode(p_map_id integer, p_player_thing_id integer) RETURNS text
LANGUAGE cedarscript AS $doom$
-- Select the movement implementation after this tic's special activation and
-- sector-mover step.
UPDATE game_tic_commands g
SET movement_mode=CASE
  WHEN NOT ps.alive THEN 'idle'
  WHEN ABS(g.move_fwd)>0 OR ABS(g.move_strafe)>0
    OR ABS(ps.momentum_x)>0.0000001 OR ABS(ps.momentum_y)>0.0000001
    OR ABS(ps.momentum_z)>0.0000001
    OR ps.bob_strength>0.0000001
    OR ABS(ps.view_z-ps.base_z)>0.0000001
    OR EXISTS (
      SELECT 1 FROM sector_movers sm
      WHERE sm.map_id=g.map_id AND sm.direction<>2
    )
    THEN 'full'
  WHEN ABS(g.turn_degrees)>0.0000001 THEN 'turn'
  ELSE 'idle'
END
FROM player_state ps
WHERE g.map_id=p_map_id::int AND g.player_thing_id=p_player_thing_id::int
  AND ps.map_id=g.map_id AND ps.player_thing_id=g.player_thing_id;

-- Normalize the movement endpoints on an idle tic. Without this,
-- previous_x/y would still describe the last moving tic and SQL would
-- repeatedly rediscover the same crossing/pickup on every idle tic.
UPDATE player_state ps
SET previous_x=ps.position_x,previous_y=ps.position_y,
    momentum_x=0,momentum_y=0,bob_strength=0,
    view_z=CASE WHEN ps.alive THEN ps.base_z ELSE ps.view_z END,
    previous_view_z=CASE WHEN ps.alive THEN ps.base_z ELSE ps.view_z END,
    previous_view_angle=ps.view_angle
FROM game_tic_commands g
WHERE ps.map_id=p_map_id::int AND ps.player_thing_id=p_player_thing_id::int
  AND g.map_id=ps.map_id AND g.player_thing_id=ps.player_thing_id
  AND g.movement_mode='idle';
let mut result_mode = 'idle'::text;
SELECT movement_mode
FROM game_tic_commands
WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int
{ result_mode = movement_mode; }
return result_mode;
$doom$;
