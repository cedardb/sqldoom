WITH classified AS (
  SELECT ld.id AS line_id,ld.special,v1.x AS x1,v1.y AS y1,
         v2.x AS x2,v2.y AS y2,
         CASE
           WHEN ld.special<>0 THEN 'special'
           WHEN rs.sector_id IS NULL OR ls.sector_id IS NULL
                OR (ld.flags & 1)<>0 THEN 'wall'
           WHEN rsec.floor_height<>lsec.floor_height THEN 'floor'
           WHEN rsec.ceil_height<>lsec.ceil_height THEN 'ceiling'
           ELSE 'internal'
         END AS kind
  FROM linedefs ld
  JOIN vertexes v1 ON v1.map_id=ld.map_id AND v1.id=ld.v1_id
  JOIN vertexes v2 ON v2.map_id=ld.map_id AND v2.id=ld.v2_id
  LEFT JOIN sidedefs rs
    ON rs.map_id=ld.map_id AND rs.id=ld.right_sd_id
  LEFT JOIN sidedefs ls
    ON ls.map_id=ld.map_id AND ls.id=ld.left_sd_id
  LEFT JOIN sectors rsec
    ON rsec.map_id=ld.map_id AND rsec.id=rs.sector_id
  LEFT JOIN sectors lsec
    ON lsec.map_id=ld.map_id AND lsec.id=ls.sector_id
  WHERE ld.map_id=%s
)
SELECT x1,y1,x2,y2,kind,line_id,special,
       MIN(LEAST(x1,x2)) OVER () AS min_x,MIN(LEAST(y1,y2)) OVER () AS min_y,
       MAX(GREATEST(x1,x2)) OVER () AS max_x,MAX(GREATEST(y1,y2)) OVER () AS max_y
FROM classified
ORDER BY CASE kind WHEN 'internal' THEN 0 WHEN 'ceiling' THEN 1
                   WHEN 'floor' THEN 2 WHEN 'wall' THEN 3 ELSE 4 END,
         line_id;
