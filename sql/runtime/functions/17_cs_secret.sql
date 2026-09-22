CREATE OR REPLACE FUNCTION doom_cs_secret(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
-- Record first entry into a vanilla secret sector.
WITH params AS (
  SELECT ps.map_id,ps.player_thing_id,ps.sector_id
  FROM player_state ps
  WHERE ps.map_id=p_map_id::int AND ps.player_thing_id=p_player_thing_id::int
)
INSERT INTO level_secret_discoveries (map_id,player_thing_id,sector_id)
SELECT p.map_id,p.player_thing_id,p.sector_id
FROM params p
JOIN sectors s ON s.map_id=p.map_id AND s.id=p.sector_id
JOIN sector_special_defs sd ON sd.special=s.special AND sd.is_secret
WHERE NOT EXISTS (
    SELECT 1 FROM level_secret_discoveries d
    WHERE d.map_id=p.map_id AND d.player_thing_id=p.player_thing_id
      AND d.sector_id=p.sector_id
  )
ON CONFLICT DO NOTHING;
$doom$;
