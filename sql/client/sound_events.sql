-- Project every sound event newer than the client's playback cursor.
WITH listener AS (
  SELECT t.x::double precision AS px,t.y::double precision AS py,
         radians(t.angle::double precision) AS angle
  FROM things t WHERE t.map_id=$1 AND t.id=$2
),
positioned AS (
  SELECT e.event_id,e.sound_name,
         CASE WHEN e.source_x IS NULL THEN 0.0
              ELSE sqrt(power(e.source_x-l.px,2)+power(e.source_y-l.py,2))
         END AS distance,
         CASE WHEN e.source_x IS NULL THEN 0.0
              ELSE sin(atan2(e.source_y-l.py,e.source_x-l.px)-l.angle)
         END AS pan
  FROM sound_events e CROSS JOIN listener l
  WHERE e.map_id=$3 AND e.event_id>$4
)
SELECT event_id,sound_name,
       CASE WHEN distance<=160.0 THEN 1.0
            WHEN distance>=1200.0 THEN 0.0
            ELSE 1.0-(distance-160.0)/1040.0 END AS volume,
       GREATEST(-1.0,LEAST(1.0,pan)) AS pan
FROM positioned
ORDER BY event_id;
