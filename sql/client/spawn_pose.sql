-- The spawn pose the client seeds its interpolated camera with. z is the eye
-- height doom_spawn_player just wrote, not the Thing's floor z.
SELECT t.x, t.y, t.angle, ps.view_z
FROM things t
JOIN player_state ps
  ON ps.map_id = t.map_id AND ps.player_thing_id = t.id
JOIN thing_role_defs r ON r.thing_type = t.type AND r.player_number = 1
WHERE t.map_id = $1 AND t.id = $2;
