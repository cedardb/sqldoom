-- Recursive bsp tree descend to find the sector
-- on the given map where the givoin point is in
CREATE OR REPLACE FUNCTION doom_sector_at(p_map_id integer, p_x double precision, p_y double precision)
RETURNS integer
LANGUAGE cedarscript AS $geo$
let mut sector = NULL::int;
WITH RECURSIVE bsp AS (
  -- The root is the highest-numbered node
  (SELECT 1 AS depth, n.id AS node_id, NULL::int AS ssector_id
   FROM nodes n WHERE n.map_id = p_map_id
   ORDER BY n.id DESC LIMIT 1)
  UNION ALL
  SELECT w.depth + 1,
         CASE WHEN nc.child_kind = 'NODE' THEN nc.child_node_id END,
         CASE WHEN nc.child_kind = 'SSECTOR' THEN nc.child_ssector_id END
  FROM bsp w
  JOIN nodes n ON n.map_id = p_map_id AND n.id = w.node_id
  JOIN node_children nc ON nc.map_id = p_map_id AND nc.node_id = n.id
    AND nc.side = CASE
      WHEN (p_x - n.x) * n.dy::float8 - (p_y - n.y) * n.dx::float8 > 0
      THEN 'R' ELSE 'L' END
  WHERE w.node_id IS NOT NULL
)
SELECT rs.fsec AS f
FROM bsp b
JOIN render_segs rs ON rs.map_id = p_map_id AND rs.ssector_id = b.ssector_id
WHERE b.ssector_id IS NOT NULL
ORDER BY rs.seg_id
LIMIT 1
{ sector = f; }
return sector;
$geo$;
