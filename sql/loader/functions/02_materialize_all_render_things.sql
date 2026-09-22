CREATE OR REPLACE FUNCTION doom_materialize_all_render_things()
LANGUAGE cedarscript AS $doom$
DELETE FROM render_things;

WITH RECURSIVE
roots AS (
  SELECT map_id,MAX(id) AS node_id
  FROM nodes
  GROUP BY map_id
),
thing_bsp AS (
  SELECT t.map_id,t.id AS thing_id,t.x AS tx,t.y AS ty,
         r.node_id,NULL::int AS ssector_id
  FROM things t
  JOIN thing_sprite_defs d ON d.thing_type=t.type
  JOIN roots r ON r.map_id=t.map_id

  UNION ALL

  SELECT b.map_id,b.thing_id,b.tx,b.ty,
         CASE WHEN nc.child_kind='NODE' THEN nc.child_node_id END,
         CASE WHEN nc.child_kind='SSECTOR' THEN nc.child_ssector_id END
  FROM thing_bsp b
  JOIN nodes n ON n.map_id=b.map_id AND n.id=b.node_id
  JOIN node_children nc
    ON nc.map_id=b.map_id AND nc.node_id=n.id
   AND nc.side=CASE
     WHEN (b.tx-n.x)::float8*n.dy::float8
        -(b.ty-n.y)::float8*n.dx::float8>0
     THEN 'R' ELSE 'L' END
  WHERE b.node_id IS NOT NULL
),
located AS (
  SELECT b.map_id,b.thing_id,rs.fsec AS sector_id,
         ROW_NUMBER() OVER (
           PARTITION BY b.map_id,b.thing_id ORDER BY rs.seg_id
         ) AS rn
  FROM thing_bsp b
  JOIN render_segs rs
    ON rs.map_id=b.map_id AND rs.ssector_id=b.ssector_id
  WHERE b.ssector_id IS NOT NULL
)
INSERT INTO render_things (
  map_id,thing_id,sector_id,spawn_sector_id,sprite,frame,fullbright,
  spawn_ceiling,thing_height
)
SELECT l.map_id,l.thing_id,l.sector_id,l.sector_id,
       d.sprite,d.frame,d.fullbright,d.spawn_ceiling,d.thing_height
FROM located l
JOIN things t ON t.map_id=l.map_id AND t.id=l.thing_id
JOIN thing_sprite_defs d ON d.thing_type=t.type
WHERE l.rn=1;
$doom$;
