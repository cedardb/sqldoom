CREATE OR REPLACE FUNCTION doom_cs_death(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
-- P_DeathThink's view drop, which is the whole of Doom's "death screen".
--
-- Doom has no death screen. When you die the view sinks from the normal
-- 41-unit eye height to 6 units, one unit per tic, so the camera settles on
-- the floor beside your own corpse
UPDATE player_state ps
SET view_z = GREATEST(s.floor_height::float8 + 6.0, ps.view_z - 1.0),
    previous_view_z = ps.view_z, previous_view_angle = ps.view_angle,
    damage_count = GREATEST(0, ps.damage_count - 1),
    death_tics = ps.death_tics + 1,
    momentum_x = 0, momentum_y = 0, momentum_z = 0, bob_strength = 0
FROM sectors s
WHERE ps.map_id = p_map_id::int
  AND ps.player_thing_id = p_player_thing_id::int
  AND NOT ps.alive
  AND s.map_id = ps.map_id AND s.id = ps.sector_id;
$doom$;
