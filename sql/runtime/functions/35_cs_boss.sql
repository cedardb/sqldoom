CREATE OR REPLACE FUNCTION doom_cs_boss(p_map_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
let mut ready = 0;

-- A map with no boss row, or one whose boss Things were filtered out by the
-- skill, has no group here
SELECT COALESCE(MAX(CASE WHEN q.alive_bosses = 0 THEN 1 ELSE 0 END), 0) AS r
FROM (
  SELECT SUM(CASE WHEN h.alive THEN 1 ELSE 0 END) AS alive_bosses
  FROM boss_actions ba
  JOIN maps m ON m.name = ba.map_name AND m.map_id = p_map_id::int
  JOIN things t ON t.map_id = m.map_id AND t.type = ba.boss_type
  JOIN thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id
  WHERE ba.action = 'lower_666'
  GROUP BY ba.map_name
) q
{ ready = r; }

if ready <> 0 {
-- EV_DoFloor(line, lowerFloorToLowest) against tag 666
WITH adjacency AS (
  SELECT sector_id, other_id FROM sector_adjacency
  WHERE map_id=p_map_id::int AND sector_id<>other_id
),
targets AS (
  SELECT s.id AS sector_id, s.floor_height,
         MIN(other.floor_height) AS lowest_floor
  FROM sectors s
  JOIN adjacency a ON a.sector_id=s.id
  JOIN sectors other ON other.map_id=s.map_id AND other.id=a.other_id
  WHERE s.map_id=p_map_id::int AND s.tag=666
  GROUP BY s.id, s.floor_height
)
INSERT INTO sector_movers
  (map_id,sector_id,source_line_id,mover_type,plane,direction,
   bottom_height,top_height,speed,wait_tics,countdown,
   next_ceiling,next_floor,target_floor_tex,moved_this_tick)
SELECT p_map_id::int,sector_id,NULL,'floor_lower','floor',-1,
       lowest_floor::smallint,floor_height,1,0,0,NULL,NULL,NULL,FALSE
FROM targets
WHERE lowest_floor < floor_height
ON CONFLICT (map_id,sector_id) DO NOTHING;
}
return ready;
$doom$;
