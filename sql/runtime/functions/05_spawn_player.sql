CREATE OR REPLACE FUNCTION doom_spawn_player(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let view_height = doom_const('VIEWHEIGHT');
-- Initialize a player at its immutable WAD Thing start.
WITH
spawn AS (
  SELECT t.map_id,t.id AS player_thing_id,
         t.x::float8 AS x,t.y::float8 AS y,
         t.angle::float8 AS angle
  FROM things t
  JOIN thing_role_defs r ON r.thing_type=t.type AND r.is_player_start
  WHERE t.map_id=p_map_id::int AND t.id=p_player_thing_id::int
),
pose AS (
  SELECT p.*,s.floor_height::float8+view_height AS view_z,s.id AS sector_id
  FROM spawn p
  JOIN sectors s ON s.map_id=p.map_id
   AND s.id=doom_sector_at(p.map_id,p.x,p.y)
)
UPDATE player_state ps
SET previous_x=p.x,previous_y=p.y,
    position_x=p.x,position_y=p.y,
    base_z=p.view_z,view_z=p.view_z,view_angle=p.angle,
    previous_view_z=p.view_z,previous_view_angle=p.angle,
    momentum_x=0,momentum_y=0,bob_strength=0,
    sector_id=p.sector_id
FROM pose p
WHERE ps.map_id=p.map_id AND ps.player_thing_id=p.player_thing_id;

-- Mirror the initialized SQL pose to the Thing read by rendering and combat.
UPDATE things t
SET x=ps.position_x,y=ps.position_y,z=ps.view_z,angle=ps.view_angle
FROM player_state ps
WHERE t.map_id=p_map_id::int AND t.id=p_player_thing_id::int
  AND ps.map_id=t.map_id AND ps.player_thing_id=t.id;
$doom$;
