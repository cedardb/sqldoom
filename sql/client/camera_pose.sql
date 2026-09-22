-- The camera between two tics. $3 is how far the client's clock has run into
-- the tic that has not happened yet: 0 draws the pose one tic ago, 1 the
-- current one.
SELECT ps.previous_x + (ps.position_x - ps.previous_x) * k.a AS x,
       ps.previous_y + (ps.position_y - ps.previous_y) * k.a AS y,
       ps.previous_view_z + (ps.view_z - ps.previous_view_z) * k.a AS z,
       w.a0 + t.turn * k.a - 360.0 * FLOOR((w.a0 + t.turn * k.a) / 360.0) AS angle
FROM player_state ps
CROSS JOIN LATERAL (SELECT LEAST(1.0, GREATEST(0.0, $3::float8)) AS a) k
CROSS JOIN LATERAL (
  SELECT ps.previous_view_angle::float8 AS a0,
         ps.view_angle::float8 - ps.previous_view_angle::float8 + 180.0 AS d
) w
CROSS JOIN LATERAL (SELECT (w.d - 360.0 * FLOOR(w.d / 360.0)) - 180.0 AS turn) t
WHERE ps.map_id = $1 AND ps.player_thing_id = $2;
