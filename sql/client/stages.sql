WITH ranked AS (
  SELECT m.map_id,m.name,w.wad_path,t.id AS player_thing_id,
         ROW_NUMBER() OVER (
           PARTITION BY w.wad_path,m.name ORDER BY m.map_id
         ) AS copy_number
  FROM maps m
  JOIN wads w ON w.wad_id=m.wad_id
  JOIN things t ON t.map_id=m.map_id
  JOIN thing_role_defs r ON r.thing_type=t.type AND r.player_number=1
)
SELECT map_id,name,wad_path,player_thing_id
FROM ranked WHERE copy_number=1 ORDER BY wad_path,name;
