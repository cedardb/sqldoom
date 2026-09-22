CREATE OR REPLACE FUNCTION doom_cs_use(p_map_id integer, p_player_thing_id integer) RETURNS boolean
LANGUAGE cedarscript AS $doom$
let use_range = doom_const('USERANGE');
-- Trace the first usable/blocking line within USERANGE and queue a supported
-- use-special for the special-activation function.
DELETE FROM line_use_results
WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id;

WITH
params AS (
  SELECT g.map_id,g.player_thing_id,
         t.x::float8 AS px,t.y::float8 AS py,
         COS(RADIANS(t.angle::float8)) AS dx,
         SIN(RADIANS(t.angle::float8)) AS dy,
         use_range AS use_range
  FROM game_tic_commands g
  JOIN things t ON t.map_id=g.map_id AND t.id=g.player_thing_id
  WHERE g.map_id=p_map_id::int AND g.player_thing_id=p_player_thing_id::int
    AND g.use_requested
),
line_geom AS (
  SELECT ld.linedef_id AS id,ld.special,ld.flags,ld.left_sd_id,ld.right_sd_id,
         ld.x1::float8 AS x1,ld.y1::float8 AS y1,
         ld.x2::float8 AS x2,ld.y2::float8 AS y2,
         rf.floor_height AS front_floor,rf.ceil_height AS front_ceil,
         rb.floor_height AS back_floor,rb.ceil_height AS back_ceil
  FROM params p
  JOIN linedef_geom ld ON ld.map_id=p.map_id
  LEFT JOIN sectors rf ON rf.map_id=ld.map_id AND rf.id=ld.fsec
  LEFT JOIN sectors rb ON rb.map_id=ld.map_id AND rb.id=ld.bsec
),
intersections AS (
  SELECT l.*,
    ((l.x1-p.px)*(l.y2-l.y1)-(l.y1-p.py)*(l.x2-l.x1))/d.denom AS distance,
    ((l.x1-p.px)*p.dy-(l.y1-p.py)*p.dx)/d.denom AS line_fraction,
    ((l.x2-l.x1)*(p.py-l.y1)-(l.y2-l.y1)*(p.px-l.x1)) < 0 AS from_front
  FROM line_geom l CROSS JOIN params p
  CROSS JOIN LATERAL (
    SELECT p.dx*(l.y2-l.y1)-p.dy*(l.x2-l.x1) AS denom
  ) d
  WHERE ABS(d.denom)>1e-9
),
trace_candidates AS (
  SELECT i.* FROM intersections i CROSS JOIN params p
  WHERE i.distance BETWEEN 0 AND p.use_range
    AND i.line_fraction BETWEEN 0 AND 1
    AND (i.special<>0 OR i.left_sd_id=-1 OR i.right_sd_id=-1
      OR (i.flags&1)<>0
      OR (LEAST(i.front_ceil,i.back_ceil)
        - GREATEST(i.front_floor,i.back_floor))<=0)
),
hit AS (SELECT * FROM trace_candidates ORDER BY distance,id LIMIT 1),
decision AS (
  SELECT h.*,
    COALESCE((d.key_required='red'    AND NOT ps.key_red)
          OR (d.key_required='blue'   AND NOT ps.key_blue)
          OR (d.key_required='yellow' AND NOT ps.key_yellow),FALSE) AS locked,
    (h.from_front AND COALESCE(d.use_activated,FALSE)) AS supported,
    COALESCE(d.use_once,FALSE) AS one_shot
  FROM hit h CROSS JOIN params p
  LEFT JOIN line_special_defs d ON d.special=h.special
  JOIN player_state ps ON ps.map_id=p.map_id
    AND ps.player_thing_id=p.player_thing_id
)
INSERT INTO line_use_results
  (map_id,player_thing_id,line_id,special,locked,eligible,from_front)
SELECT p.map_id,p.player_thing_id,d.id,d.special,d.locked,
       d.supported AND NOT d.locked
         AND NOT (d.one_shot AND EXISTS (
           SELECT 1 FROM line_activations a
           WHERE a.map_id=p.map_id AND a.line_id=d.id
         )),
       d.from_front
FROM decision d CROSS JOIN params p;

-- Queue the staged decision.
INSERT INTO line_special_events
  (map_id,player_thing_id,line_id,trigger_type,from_front)
SELECT map_id,player_thing_id,line_id,'use',from_front
FROM line_use_results
WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id AND eligible
ON CONFLICT (map_id,player_thing_id,line_id,trigger_type) DO NOTHING;
let mut result_queued = false;
SELECT COALESCE(r.eligible,FALSE) AS queued,
       r.line_id,
       COALESCE(r.locked,FALSE) AS locked,
       CASE WHEN COALESCE(r.locked,FALSE) THEN d.key_required::text END
         AS required_key,
       COALESCE(r.eligible AND d.is_exit,FALSE) AS is_exit,
       COALESCE(r.eligible AND d.secret_exit,FALSE) AS exit_secret
FROM (SELECT p_map_id::int AS map_id, p_player_thing_id::int AS player_thing_id) p
LEFT JOIN line_use_results r ON r.map_id=p.map_id
  AND r.player_thing_id=p.player_thing_id
LEFT JOIN line_special_defs d ON d.special=r.special
{ result_queued = queued; }
return result_queued;
$doom$;
