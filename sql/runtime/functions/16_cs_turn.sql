CREATE OR REPLACE FUNCTION doom_cs_turn(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
-- Prepared stationary turn fast path
UPDATE player_state ps
SET previous_x=t.x,previous_y=t.y,
    position_x=t.x,position_y=t.y,
    view_angle=(t.angle-g.turn_degrees::float8)
      -360.0*FLOOR((t.angle-g.turn_degrees::float8)/360.0),
    previous_view_angle=ps.view_angle,previous_view_z=ps.view_z,
    momentum_x=0,momentum_y=0,bob_strength=0,view_z=ps.base_z
FROM things t,game_tic_commands g
WHERE ps.map_id=p_map_id::int AND ps.player_thing_id=p_player_thing_id::int
  AND t.map_id=ps.map_id AND t.id=ps.player_thing_id
  AND g.map_id=ps.map_id AND g.player_thing_id=ps.player_thing_id
  AND g.movement_mode='turn';

UPDATE things t
SET angle=ps.view_angle
FROM player_state ps
WHERE t.map_id=p_map_id::int AND t.id=p_player_thing_id::int
  AND ps.map_id=t.map_id AND ps.player_thing_id=t.id
  AND EXISTS (
    SELECT 1 FROM game_tic_commands g
    WHERE g.map_id=t.map_id AND g.player_thing_id=t.id
      AND g.movement_mode='turn'
  );
$doom$;
