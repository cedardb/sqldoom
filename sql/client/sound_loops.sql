-- Project the complete current loop set from SQL gameplay state.
WITH input AS (
  SELECT $1::int AS map_id,$2::int AS player_thing_id
),
listener AS (
  SELECT t.x::double precision AS px,t.y::double precision AS py,
         radians(t.angle::double precision) AS angle
  FROM things t JOIN input i ON t.map_id=i.map_id AND t.id=i.player_thing_id
),
loops AS (
  SELECT 'mover:'||sm.sector_id::text AS loop_key,
         'DSSTNMOV'::text AS sound_name,
         so.x::double precision AS source_x,
         so.y::double precision AS source_y
  FROM sector_movers sm
  JOIN input i ON i.map_id=sm.map_id
  JOIN sector_sound_origins so ON so.map_id=sm.map_id
    AND so.sector_id=sm.sector_id
  WHERE sm.direction IN (-1,1)
  UNION ALL
  SELECT 'chainsaw:'||i.player_thing_id::text,
         CASE WHEN pw.state='fire' THEN 'DSSAWFUL' ELSE 'DSSAWIDL' END,
         NULL::double precision,NULL::double precision
  FROM input i JOIN player_weapons pw ON pw.map_id=i.map_id
    AND pw.player_thing_id=i.player_thing_id
  WHERE pw.current_weapon=8 AND pw.state<>'down'
),
positioned AS (
  SELECT l.loop_key,l.sound_name,
         CASE WHEN l.source_x IS NULL THEN 0.0
              ELSE sqrt(power(l.source_x-p.px,2)+power(l.source_y-p.py,2))
         END AS distance,
         CASE WHEN l.source_x IS NULL THEN 0.0
              ELSE sin(atan2(l.source_y-p.py,l.source_x-p.px)-p.angle)
         END AS pan
  FROM loops l CROSS JOIN listener p
)
SELECT loop_key,sound_name,
       CASE WHEN distance<=160.0 THEN 1.0
            WHEN distance>=1200.0 THEN 0.0
            ELSE 1.0-(distance-160.0)/1040.0 END AS volume,
       GREATEST(-1.0,LEAST(1.0,pan)) AS pan
FROM positioned ORDER BY loop_key;
