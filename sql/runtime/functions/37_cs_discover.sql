CREATE OR REPLACE FUNCTION doom_cs_discover(p_map_id integer, p_player_thing_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
-- Reveal the automap as the player walks it.
INSERT INTO mapped_lines (map_id, line_id)
SELECT ps.map_id, ld.id
FROM player_state ps
JOIN linedefs ld ON ld.map_id = ps.map_id
LEFT JOIN sidedefs rs ON rs.map_id = ld.map_id AND rs.id = ld.right_sd_id
LEFT JOIN sidedefs ls ON ls.map_id = ld.map_id AND ls.id = ld.left_sd_id
WHERE ps.map_id = p_map_id::int
  AND ps.player_thing_id = p_player_thing_id::int
  AND ps.sector_id IS NOT NULL
  AND (rs.sector_id = ps.sector_id OR ls.sector_id = ps.sector_id)
ON CONFLICT (map_id, line_id) DO NOTHING;
return 0;
$doom$;
