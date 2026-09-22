CREATE OR REPLACE FUNCTION doom_materialize_render_segs(p_map_id integer)
LANGUAGE cedarscript AS $doom$
DELETE FROM render_segs WHERE map_id=p_map_id;

INSERT INTO render_segs (
  map_id,seg_id,ssector_id,direction,linedef_id,x1,y1,x2,y2,
  seg_u1,seg_u2,fsec,bsec,x_offset,y_offset,
  upper_tex,mid_tex,lower_tex,flags,
  f_floor,f_ceil,f_ceil_tex,f_light,
  b_floor,b_ceil,b_ceil_tex,b_light,light_bias
)
SELECT
  sg.map_id,sg.id,ss.id,sg.direction,sg.linedef_id,
  v1.x,v1.y,v2.x,v2.y,
  CASE WHEN sg.direction=0 THEN sg.offs
       ELSE sg.offs+sqrt((v2.x-v1.x)^2+(v2.y-v1.y)^2)::double precision END,
  CASE WHEN sg.direction=0
       THEN sg.offs+sqrt((v2.x-v1.x)^2+(v2.y-v1.y)^2)::double precision
       ELSE sg.offs END,
  fs.id,bs.id,front.x_offset,front.y_offset,
  front.upper_tex,front.mid_tex,front.lower_tex,ld.flags,
  fs.floor_height,fs.ceil_height,fs.ceil_tex,fs.light_level,
  bs.floor_height,bs.ceil_height,bs.ceil_tex,bs.light_level,
  CASE WHEN v1.y=v2.y THEN -1 WHEN v1.x=v2.x THEN 1 ELSE 0 END
FROM segs sg
JOIN ssectors ss ON ss.map_id=sg.map_id
  AND sg.id>=ss.first_seg_id
  AND sg.id<ss.first_seg_id+ss.seg_count
JOIN vertexes v1 ON v1.map_id=sg.map_id AND v1.id=sg.v1_id
JOIN vertexes v2 ON v2.map_id=sg.map_id AND v2.id=sg.v2_id
JOIN linedefs ld ON ld.map_id=sg.map_id AND ld.id=sg.linedef_id
JOIN sidedefs front ON front.map_id=sg.map_id
  AND front.id=CASE WHEN sg.direction=0 THEN ld.right_sd_id ELSE ld.left_sd_id END
LEFT JOIN sidedefs back ON back.map_id=sg.map_id
  AND back.id=CASE WHEN sg.direction=0 THEN ld.left_sd_id ELSE ld.right_sd_id END
JOIN sectors fs ON fs.map_id=sg.map_id AND fs.id=front.sector_id
LEFT JOIN sectors bs ON bs.map_id=sg.map_id AND bs.id=back.sector_id
WHERE sg.map_id=p_map_id;

DELETE FROM sector_sound_origins WHERE map_id=p_map_id;

INSERT INTO sector_sound_origins(map_id,sector_id,x,y)
SELECT map_id,sector_id,AVG(x)::real,AVG(y)::real
FROM (
  SELECT map_id,fsec AS sector_id,x1 AS x,y1 AS y
  FROM render_segs WHERE map_id=p_map_id
  UNION ALL
  SELECT map_id,bsec,x1,y1
  FROM render_segs WHERE map_id=p_map_id AND bsec IS NOT NULL
) boundary
GROUP BY map_id,sector_id;
$doom$;
