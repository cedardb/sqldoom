CREATE OR REPLACE FUNCTION doom_cs_activate_specials(p_map_id integer) RETURNS bigint
LANGUAGE cedarscript AS $doom$
let mut flags = 0::bigint;
DELETE FROM line_special_events e
USING linedefs ld, line_special_defs d
WHERE e.map_id=p_map_id AND ld.map_id=e.map_id AND ld.id=e.line_id AND d.special=ld.special
  AND EXISTS (
    SELECT 1 FROM line_special_events e2
    JOIN linedefs ld2 ON ld2.map_id=e2.map_id AND ld2.id=e2.line_id
    JOIN line_special_defs d2 ON d2.special=ld2.special
    WHERE e2.map_id=e.map_id AND d2.mechanic=d.mechanic
      AND ((ld.tag<>0 AND ld2.tag=ld.tag) OR (ld.tag=0 AND ld2.id=ld.id))
      AND (ld2.id<ld.id OR (ld2.id=ld.id AND e2.player_thing_id<e.player_thing_id)));

-- Dispatch plan for queued linedef specials
WITH events AS (
  SELECT e.map_id,e.line_id,ld.special,ld.right_sd_id,d.mechanic,d.flips_switch,
         (COALESCE(d.cross_once,FALSE) OR COALESCE(d.use_once,FALSE)) AS one_shot,
         (COALESCE(d.cross_once,FALSE) OR COALESCE(d.use_once,FALSE))
          AND EXISTS (
            SELECT 1 FROM line_activations a
            WHERE a.map_id=e.map_id AND a.line_id=e.line_id
          ) AS stale,
         (COALESCE(sd.upper_tex,'') LIKE 'SW1%'
          OR COALESCE(sd.mid_tex,'') LIKE 'SW1%'
          OR COALESCE(sd.lower_tex,'') LIKE 'SW1%') AS has_switch_texture
  FROM line_special_events e
  JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
  LEFT JOIN line_special_defs d ON d.special=ld.special
  LEFT JOIN sidedefs sd ON sd.map_id=ld.map_id AND sd.id=ld.right_sd_id
  WHERE e.map_id=p_map_id::int
)
SELECT
  COALESCE(BOOL_OR(stale),FALSE) AS stale_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='door'),FALSE) AS doors_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='floor'),FALSE) AS floors_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='platform'),FALSE) AS lifts_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='donut'),FALSE) AS donuts_due,
  COALESCE(BOOL_OR(NOT stale AND has_switch_texture AND flips_switch),FALSE) AS buttons_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='raise'),FALSE) AS raises_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='stairs'),FALSE) AS stairs_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='lights'),FALSE) AS lights_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='teleport'),FALSE) AS teleport_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='ceiling'),FALSE) AS ceilings_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='crusher'),FALSE) AS crushers_due,
  COALESCE(BOOL_OR(NOT stale AND mechanic='stop'),FALSE) AS stops_due,
  COALESCE(BOOL_OR(NOT stale AND one_shot),FALSE) AS activation_due
FROM events
{
  if stale_due { flags = flags + 1; }
  if doors_due { flags = flags + 2; }
  if floors_due { flags = flags + 4; }
  if lifts_due { flags = flags + 8; }
  if donuts_due { flags = flags + 16; }
  if buttons_due { flags = flags + 32; }
  if activation_due { flags = flags + 64; }
  if raises_due { flags = flags + 128; }
  if stairs_due { flags = flags + 256; }
  if lights_due { flags = flags + 512; }
  if teleport_due { flags = flags + 1024; }
  if ceilings_due { flags = flags + 2048; }
  if crushers_due { flags = flags + 4096; }
  if stops_due { flags = flags + 8192; }
}
if (flags & 1) <> 0 {
-- Consume queued use/cross/shoot linedef events and instantiate Doom-style
-- tagged sector movers.

-- The script is executed as separately prepared statements on an autocommit
-- connection.  If execution is interrupted after recording a one-shot
-- activation but before deleting its queued event, the event survives while
-- the activation marker is already committed.  Drop such stale events before
-- dispatching anything: replaying their effects is wrong, and attempting to
-- record the same marker again produces a duplicate-primary-key error on
-- CedarDB even with ON CONFLICT DO NOTHING.
DELETE FROM line_special_events e
WHERE e.map_id=p_map_id AND EXISTS (
  SELECT 1
  FROM linedefs ld JOIN line_activations a
    ON a.map_id=ld.map_id AND a.line_id=ld.id
  JOIN line_special_defs d ON d.special=ld.special
    AND (d.cross_once OR d.use_once)
  WHERE ld.map_id=e.map_id AND ld.id=e.line_id
);
}
if (flags & 2) <> 0 {
-- Doors: manual back-sector doors plus tagged remote doors.
WITH
events AS (
  SELECT e.map_id,e.line_id,e.trigger_type,ld.special,ld.tag,ld.left_sd_id
  FROM line_special_events e
  JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
  WHERE e.map_id=p_map_id
),
door_sectors AS (
  -- 'back' is the manual door you open by walking into it, which moves the
  -- sector behind the line; 'tag' is a remote door, which moves every sector
  -- carrying the line's tag.
  SELECT e.*,
    CASE WHEN d.door_target='back' THEN back.sector_id ELSE s.id END AS sector_id
  FROM events e
  JOIN line_special_defs d ON d.special=e.special AND d.mechanic='door'
  LEFT JOIN sidedefs back ON back.map_id=e.map_id AND back.id=e.left_sd_id
  LEFT JOIN sectors s ON s.map_id=e.map_id AND s.tag=e.tag
  WHERE (d.door_target='back' AND back.sector_id IS NOT NULL)
     OR (d.door_target='tag'  AND s.id IS NOT NULL)
),
adjacency AS (
  SELECT sector_id, other_id FROM sector_adjacency
  WHERE map_id=p_map_id AND sector_id<>other_id
),
neighbors AS (
  SELECT d.map_id,d.line_id,d.special,d.sector_id,other.ceil_height
  FROM door_sectors d
  JOIN adjacency a ON a.sector_id=d.sector_id
  JOIN sectors other ON other.map_id=d.map_id AND other.id=a.other_id
),
targets AS (
  SELECT d.map_id,d.line_id,d.special,d.sector_id,s.floor_height,s.ceil_height,
    GREATEST(s.ceil_height,COALESCE(MIN(n.ceil_height)-4,s.ceil_height))::smallint
      AS open_height
  FROM door_sectors d
  JOIN sectors s ON s.map_id=d.map_id AND s.id=d.sector_id
  LEFT JOIN neighbors n ON n.map_id=d.map_id AND n.line_id=d.line_id
    AND n.sector_id=d.sector_id
  GROUP BY d.map_id,d.line_id,d.special,d.sector_id,s.floor_height,s.ceil_height
),
targets_unique AS (
  SELECT * FROM (
    SELECT t.*,ROW_NUMBER() OVER
      (PARTITION BY t.map_id,t.sector_id ORDER BY t.line_id) AS rn
    FROM targets t) q
  WHERE rn=1
)
INSERT INTO sector_movers
  (map_id,sector_id,source_line_id,mover_type,plane,direction,
   bottom_height,top_height,speed,wait_tics,countdown,
   next_ceiling,next_floor,target_floor_tex,moved_this_tick)
SELECT t.map_id,t.sector_id,t.line_id,
  d.mover_type,
  'ceiling',
  d.direction,
  t.floor_height,
  -- A closing door's travel ends back at the ceiling it started from;
  -- everything else opens to just under the lowest neighbouring ceiling.
  CASE WHEN d.direction=-1 THEN t.ceil_height ELSE t.open_height END,
  d.speed,
  d.wait_tics,
  0,NULL,NULL,NULL,FALSE
FROM targets_unique t
JOIN line_special_defs d ON d.special=t.special
ON CONFLICT (map_id,sector_id) DO UPDATE SET
  -- A completed manual raiser (direction=2) is sitting closed, so a fresh
  -- use must start it opening again. Active doors retain Doom's use-toggle:
  -- closing reverses upward; opening/waiting starts closing. Only a manual
  -- door does this; any other mover in the sector is left alone.
  source_line_id=CASE WHEN EXCLUDED.mover_type='door_manual_raise' AND sector_movers.plane='ceiling'
                      THEN EXCLUDED.source_line_id ELSE sector_movers.source_line_id END,
  direction=CASE WHEN EXCLUDED.mover_type='door_manual_raise' AND sector_movers.plane='ceiling'
                 THEN CASE WHEN sector_movers.direction IN (-1,2) THEN 1 ELSE -1 END
                 ELSE sector_movers.direction END,
  countdown=CASE WHEN EXCLUDED.mover_type='door_manual_raise' AND sector_movers.plane='ceiling'
                 THEN 0 ELSE sector_movers.countdown END,
  next_ceiling=CASE WHEN EXCLUDED.mover_type='door_manual_raise' AND sector_movers.plane='ceiling'
                    THEN NULL ELSE sector_movers.next_ceiling END,
  moved_this_tick=CASE WHEN EXCLUDED.mover_type='door_manual_raise' AND sector_movers.plane='ceiling'
                       THEN FALSE ELSE sector_movers.moved_this_tick END;
}
if (flags & 4) <> 0 {
-- Floor lowering.
WITH
events AS (
  SELECT e.map_id,e.line_id,ld.special,ld.tag,
         d.height_target,d.mover_type,d.direction,d.speed,d.change_tex
  FROM line_special_events e JOIN linedefs ld
    ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='floor'
  WHERE e.map_id=p_map_id
),
adjacency AS (
  SELECT sector_id, other_id FROM sector_adjacency
  WHERE map_id=p_map_id AND sector_id<>other_id
),
targets AS (
  SELECT e.map_id,e.line_id,e.special,e.height_target,e.mover_type,
    e.direction,e.speed,e.change_tex,s.id AS sector_id,s.floor_height,
    MIN(other.floor_height) AS lowest_floor,
    MAX(other.floor_height) AS highest_floor
  FROM events e JOIN sectors s ON s.map_id=e.map_id AND s.tag=e.tag
  JOIN adjacency a ON a.sector_id=s.id
  JOIN sectors other ON other.map_id=s.map_id AND other.id=a.other_id
  GROUP BY e.map_id,e.line_id,e.special,e.height_target,e.mover_type,
    e.direction,e.speed,e.change_tex,s.id,s.floor_height
),
dest AS (
  -- 'lowest' drops to the lowest neighbour, 'highest' to the highest one,
  -- 'highest8' is the turbo variant that stops 8 above the highest one.
  SELECT *,CASE WHEN height_target='lowest' THEN lowest_floor
    WHEN height_target='highest' THEN highest_floor
    WHEN highest_floor<>floor_height THEN highest_floor+8
    ELSE floor_height END::smallint AS destination
  FROM targets
),
model AS (
  SELECT d.*,
    CASE WHEN d.change_tex THEN
      (SELECT o.floor_tex FROM adjacency a
        JOIN sectors o ON o.map_id=d.map_id AND o.id=a.other_id
        WHERE a.sector_id=d.sector_id AND o.floor_height=d.destination
        ORDER BY o.id LIMIT 1) END AS model_tex
  FROM dest d
)
INSERT INTO sector_movers
  (map_id,sector_id,source_line_id,mover_type,plane,direction,
   bottom_height,top_height,speed,wait_tics,countdown,
   next_ceiling,next_floor,target_floor_tex,moved_this_tick)
SELECT map_id,sector_id,line_id,mover_type,'floor',direction,
  LEAST(floor_height,destination),floor_height,
  speed,0,0,NULL,NULL,model_tex,FALSE
FROM model WHERE destination<floor_height
ON CONFLICT (map_id,sector_id) DO NOTHING;
}
if (flags & 8) <> 0 {
-- Down-wait-up lifts.
WITH
events AS (
  SELECT e.map_id,e.line_id,ld.special,ld.tag,
         d.mover_type,d.direction,d.speed,d.wait_tics
  FROM line_special_events e JOIN linedefs ld
    ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='platform'
  WHERE e.map_id=p_map_id
),
-- P_FindLowestFloorSurrounding needs the sectors on the far side of the
-- tagged sector's own two-sided lines. Deriving that as "join every linedef
-- on the map, then keep the ones whose sidedefs happen to mention this
-- sector" has no join condition at all: the real test sits in the WHERE as an
-- OR across two LEFT-joined tables, which no hash join can use, so it
-- degenerates into a nested loop over every line for every tagged sector.
-- One lift activation on E1M2 cost 219 ms because of it.
--
-- Equi-joining the sidedef ids instead gives an edge list the planner can
-- actually index, and says what it means: a two-sided line is an edge between
-- the two sectors its sidedefs name.
adjacency AS (
  SELECT sector_id, other_id FROM sector_adjacency
  WHERE map_id=p_map_id AND sector_id<>other_id
),
targets AS (
  SELECT e.map_id,e.line_id,e.mover_type,e.direction,e.speed,e.wait_tics,
    s.id AS sector_id,s.floor_height,
    MIN(other.floor_height)::smallint AS lowest_floor,
    MAX(other.floor_height)::smallint AS highest_floor
  FROM events e JOIN sectors s ON s.map_id=e.map_id AND s.tag=e.tag
  JOIN adjacency a ON a.sector_id=s.id
  JOIN sectors other ON other.map_id=s.map_id AND other.id=a.other_id
  GROUP BY e.map_id,e.line_id,e.mover_type,e.direction,e.speed,e.wait_tics,
    s.id,s.floor_height
),
targets_unique AS (
  SELECT * FROM (
    SELECT t.*,ROW_NUMBER() OVER
      (PARTITION BY t.map_id,t.sector_id ORDER BY t.line_id) AS rn
    FROM targets t) q
  WHERE rn=1
)
INSERT INTO sector_movers
  (map_id,sector_id,source_line_id,mover_type,plane,direction,
   bottom_height,top_height,speed,wait_tics,countdown,
   next_ceiling,next_floor,target_floor_tex,moved_this_tick)
SELECT map_id,sector_id,line_id,mover_type,'floor',direction,
  LEAST(floor_height,lowest_floor),
  -- A perpetual platform runs between the lowest and highest neighbours for
  -- ever (until a stop line); an ordinary lift comes back to where it was.
  CASE WHEN mover_type='platform_perpetual' THEN GREATEST(floor_height,highest_floor)
       ELSE floor_height END,
  speed,wait_tics,0,NULL,NULL,NULL,FALSE
FROM targets_unique
ON CONFLICT (map_id,sector_id) DO UPDATE SET
  source_line_id=EXCLUDED.source_line_id,direction=-1,countdown=0,
  next_floor=NULL,moved_this_tick=FALSE
WHERE sector_movers.direction=2 AND sector_movers.plane='floor';
}
if (flags & 16) <> 0 {
-- S1 donut: lower the tagged pillar and raise its surrounding ring to the
-- next outside sector's floor, adopting that sector's flat at completion.
WITH
events AS (
  SELECT e.map_id,e.line_id,ld.tag
  FROM line_special_events e JOIN linedefs ld
    ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='donut'
  WHERE e.map_id=p_map_id
),
pillar AS (
  SELECT e.map_id,e.line_id,s.id AS pillar_id,s.floor_height AS pillar_floor
  FROM events e JOIN sectors s ON s.map_id=e.map_id AND s.tag=e.tag
),
edges AS (
  SELECT sector_id, other_id, linedef_id AS edge_id
  FROM sector_adjacency WHERE map_id=p_map_id
),
ring_candidates AS (
  SELECT p.*, e.other_id AS ring_id, e.edge_id
  FROM pillar p
  JOIN edges e ON e.sector_id=p.pillar_id
),
ring AS (
  SELECT * FROM (SELECT *,ROW_NUMBER() OVER
    (PARTITION BY map_id,line_id,pillar_id ORDER BY edge_id) AS rn
    FROM ring_candidates) q WHERE rn=1
),
outside_candidates AS (
  SELECT r.*, e.other_id AS outside_id, e.edge_id AS outside_edge_id
  FROM ring r
  JOIN edges e ON e.sector_id=r.ring_id
  WHERE e.other_id <> r.pillar_id
),
outside AS (
  SELECT * FROM (SELECT *,ROW_NUMBER() OVER
    (PARTITION BY map_id,line_id,pillar_id ORDER BY outside_edge_id) AS outside_rn
    FROM outside_candidates) q WHERE outside_rn=1
),
motions AS (
  SELECT o.map_id,o.line_id,o.pillar_id AS sector_id,'floor_lower'::text AS mover_type,
    -1::smallint AS direction,LEAST(o.pillar_floor,s.floor_height)::smallint AS bottom_height,
    o.pillar_floor::smallint AS top_height,NULL::varchar(8) AS target_tex
  FROM outside o JOIN sectors s ON s.map_id=o.map_id AND s.id=o.outside_id
  UNION ALL
  SELECT o.map_id,o.line_id,o.ring_id,'donut_raise',1,
    ring.floor_height::smallint,GREATEST(ring.floor_height,s.floor_height)::smallint,
    s.floor_tex
  FROM outside o JOIN sectors ring ON ring.map_id=o.map_id AND ring.id=o.ring_id
  JOIN sectors s ON s.map_id=o.map_id AND s.id=o.outside_id
)
INSERT INTO sector_movers
  (map_id,sector_id,source_line_id,mover_type,plane,direction,
   bottom_height,top_height,speed,wait_tics,countdown,
   next_ceiling,next_floor,target_floor_tex,moved_this_tick)
SELECT map_id,sector_id,line_id,mover_type,'floor',direction,
  bottom_height,top_height,1,0,0,NULL,NULL,target_tex,FALSE
FROM motions WHERE bottom_height<>top_height
ON CONFLICT (map_id,sector_id) DO NOTHING;
}
if (flags & 32) <> 0 {
-- Remember visible SW1* texture substitutions. Repeatable buttons restore
-- after one second; S1/W1 switches stay changed until the stage resets.
-- A restored repeatable button keeps its row at countdown=0; remove that
-- stale row before reactivation.
DELETE FROM line_buttons b WHERE b.map_id=p_map_id AND b.countdown=0 AND EXISTS (
  SELECT 1 FROM line_special_events e
  WHERE e.map_id=b.map_id AND e.line_id=b.line_id
);

WITH
events AS (
  SELECT DISTINCT e.map_id,e.line_id,ld.special,ld.right_sd_id,
    (d.cross_once OR d.use_once) AS one_shot
  FROM line_special_events e JOIN linedefs ld
    ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.flips_switch
  WHERE e.map_id=p_map_id
),
parts AS (
  SELECT e.map_id,e.line_id,e.right_sd_id AS sidedef_id,'upper'::text AS texture_part,
    sd.upper_tex AS tex,
    -- A repeatable switch springs back after a second; a one-shot one
    -- stays pressed (-1).
    CASE WHEN e.one_shot THEN -1 ELSE 35 END AS countdown
  FROM events e JOIN sidedefs sd ON sd.map_id=e.map_id AND sd.id=e.right_sd_id
  WHERE sd.upper_tex LIKE 'SW1%'
  UNION ALL
  SELECT e.map_id,e.line_id,e.right_sd_id,'middle',sd.mid_tex,
    CASE WHEN e.one_shot THEN -1 ELSE 35 END
  FROM events e JOIN sidedefs sd ON sd.map_id=e.map_id AND sd.id=e.right_sd_id
  WHERE sd.mid_tex LIKE 'SW1%'
  UNION ALL
  SELECT e.map_id,e.line_id,e.right_sd_id,'lower',sd.lower_tex,
    CASE WHEN e.one_shot THEN -1 ELSE 35 END
  FROM events e JOIN sidedefs sd ON sd.map_id=e.map_id AND sd.id=e.right_sd_id
  WHERE sd.lower_tex LIKE 'SW1%'
)
INSERT INTO line_buttons
  (map_id,line_id,sidedef_id,texture_part,original_tex,active_tex,countdown,
   just_restored)
SELECT map_id,line_id,sidedef_id,texture_part,tex,
  ('SW2'||SUBSTRING(tex FROM 4))::varchar(8),countdown,FALSE
FROM parts;

WITH changed AS (
  SELECT DISTINCT b.map_id,b.sidedef_id
  FROM line_buttons b
  WHERE b.map_id=p_map_id AND EXISTS (
    SELECT 1 FROM line_special_events e
    WHERE e.map_id=b.map_id AND e.line_id=b.line_id
  )
)
UPDATE sidedefs sd
SET upper_tex=COALESCE(u.active_tex,sd.upper_tex),
    mid_tex=COALESCE(m.active_tex,sd.mid_tex),
    lower_tex=COALESCE(l.active_tex,sd.lower_tex)
FROM changed c
LEFT JOIN line_buttons u ON u.map_id=c.map_id AND u.sidedef_id=c.sidedef_id
  AND u.texture_part='upper'
LEFT JOIN line_buttons m ON m.map_id=c.map_id AND m.sidedef_id=c.sidedef_id
  AND m.texture_part='middle'
LEFT JOIN line_buttons l ON l.map_id=c.map_id AND l.sidedef_id=c.sidedef_id
  AND l.texture_part='lower'
WHERE sd.map_id=c.map_id AND sd.id=c.sidedef_id;

UPDATE render_segs rs
SET upper_tex=sd.upper_tex,mid_tex=sd.mid_tex,lower_tex=sd.lower_tex
FROM linedefs ld,sidedefs sd
WHERE rs.map_id=p_map_id AND ld.map_id=rs.map_id AND ld.id=rs.linedef_id
  AND sd.map_id=ld.map_id
  AND sd.id=CASE WHEN rs.direction=0 THEN ld.right_sd_id ELSE ld.left_sd_id END;
}
if (flags & 64) <> 0 {
-- Consume one-shot lines now, after their valid key/side/trigger event was
-- queued.
INSERT INTO line_activations (map_id,line_id)
SELECT DISTINCT e.map_id,e.line_id
FROM line_special_events e JOIN linedefs ld
  ON ld.map_id=e.map_id AND ld.id=e.line_id
JOIN line_special_defs d ON d.special=ld.special
  AND (d.cross_once OR d.use_once)
WHERE e.map_id=p_map_id;
}

if (flags & 128) <> 0 {
-- Floor RAISES. height_target says where it stops: 'lowest_ceiling' is the
-- lowest surrounding ceiling, 'next_floor' is the next floor above this on.
-- The change_tex variants additionally adopt that model sector's flat
WITH
events AS (
  SELECT e.map_id,e.line_id,ld.special,ld.tag,
         d.height_target,d.change_tex,d.mover_type,d.direction,d.speed,d.crush,
         fs.floor_tex AS front_tex
  FROM line_special_events e JOIN linedefs ld
    ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='raise'
  LEFT JOIN sidedefs fsd ON fsd.map_id=ld.map_id AND fsd.id=ld.right_sd_id
  LEFT JOIN sectors fs ON fs.map_id=ld.map_id AND fs.id=fsd.sector_id
  WHERE e.map_id=p_map_id
),
-- The shortest lower texture on the sector's two-sided lines, either side.
shortest AS (
  SELECT sec.id AS sector_id, MIN(wt.height) AS shortest
  FROM sectors sec
  JOIN sidedefs sd ON sd.map_id=sec.map_id AND sd.sector_id=sec.id
  JOIN linedefs ld ON ld.map_id=sd.map_id AND (ld.right_sd_id=sd.id OR ld.left_sd_id=sd.id)
    AND ld.right_sd_id IS NOT NULL AND ld.left_sd_id IS NOT NULL
  JOIN sidedefs both_sides ON both_sides.map_id=ld.map_id
    AND both_sides.id IN (ld.right_sd_id, ld.left_sd_id)
  JOIN walltex_meta wt ON wt.name=both_sides.lower_tex
  WHERE sec.map_id=p_map_id AND both_sides.lower_tex IS NOT NULL AND both_sides.lower_tex<>'-'
  GROUP BY sec.id
),
adjacency AS (
  SELECT sector_id, other_id FROM sector_adjacency
  WHERE map_id=p_map_id AND sector_id<>other_id
),
neighbors AS (
  SELECT e.map_id,e.line_id,e.special,e.height_target,e.change_tex,
         e.mover_type,e.direction,e.speed,e.crush,e.front_tex,
         s.id AS sector_id,s.floor_height,s.ceil_height,
         other.id AS other_id,other.floor_height AS other_floor,
         other.ceil_height AS other_ceil,other.floor_tex AS other_tex
  FROM events e JOIN sectors s ON s.map_id=e.map_id AND s.tag=e.tag
  JOIN adjacency a ON a.sector_id=s.id
  JOIN sectors other ON other.map_id=s.map_id AND other.id=a.other_id
),
targets AS (
  SELECT n.map_id,n.line_id,n.special,n.height_target,n.change_tex,n.mover_type,
    n.direction,n.speed,n.crush,n.front_tex,n.sector_id,n.floor_height,
    -- EV_DoFloor caps a raise at the sector's own ceiling
    LEAST(MIN(n.other_ceil),n.ceil_height) AS lowest_ceiling,
    MIN(CASE WHEN n.other_floor>n.floor_height THEN n.other_floor END) AS next_floor,
    MIN(sh.shortest) AS shortest_texture
  FROM neighbors n
  LEFT JOIN shortest sh ON sh.sector_id=n.sector_id
  GROUP BY n.map_id,n.line_id,n.special,n.height_target,n.change_tex,n.mover_type,
    n.direction,n.speed,n.crush,n.front_tex,n.sector_id,n.floor_height,n.ceil_height
),
dest AS (
  SELECT t.*,
    CASE t.height_target
      WHEN 'lowest_ceiling' THEN t.lowest_ceiling
      WHEN 'lowest_ceiling_minus8' THEN t.lowest_ceiling-8
      WHEN 'plus24' THEN t.floor_height+24
      WHEN 'plus32' THEN t.floor_height+32
      WHEN 'plus512' THEN t.floor_height+512
      WHEN 'shortest_texture' THEN t.floor_height+t.shortest_texture
      ELSE t.next_floor END::smallint AS destination
  FROM targets t
),
model AS (
  SELECT d.*,
    CASE WHEN d.height_target IN ('plus24','plus32') THEN d.front_tex ELSE
    (SELECT n.other_tex FROM neighbors n
      WHERE n.map_id=d.map_id AND n.line_id=d.line_id
        AND n.sector_id=d.sector_id AND n.other_floor=d.destination
      ORDER BY n.other_id LIMIT 1) END AS model_tex
  FROM dest d
)
INSERT INTO sector_movers
  (map_id,sector_id,source_line_id,mover_type,plane,direction,
   bottom_height,top_height,speed,wait_tics,countdown,
   next_ceiling,next_floor,target_floor_tex,moved_this_tick,crush)
SELECT map_id,sector_id,line_id,mover_type,'floor',direction,
  floor_height,destination,speed,0,0,NULL,NULL,
  CASE WHEN change_tex THEN model_tex END,FALSE,crush
FROM model
WHERE destination IS NOT NULL AND destination>floor_height
ON CONFLICT (map_id,sector_id) DO NOTHING;

UPDATE sectors s
SET floor_height=q.dest
FROM (
  SELECT sec.map_id,sec.id,sec.floor_height,
         (LEAST(MIN(o.ceil_height),sec.ceil_height)
          -CASE WHEN d.height_target='lowest_ceiling_minus8' THEN 8 ELSE 0 END)::smallint AS dest
  FROM line_special_events e
  JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='raise'
   AND d.height_target IN ('lowest_ceiling','lowest_ceiling_minus8')
  JOIN sectors sec ON sec.map_id=e.map_id AND sec.tag=ld.tag AND ld.tag<>0
  JOIN sector_adjacency a ON a.map_id=sec.map_id AND a.sector_id=sec.id
  JOIN sectors o ON o.map_id=a.map_id AND o.id=a.other_id
  WHERE e.map_id=p_map_id AND o.id<>sec.id
  GROUP BY sec.map_id,sec.id,sec.floor_height,sec.ceil_height,d.height_target
) q
WHERE s.map_id=q.map_id AND s.id=q.id AND q.dest<q.floor_height
  AND NOT EXISTS (SELECT 1 FROM sector_movers sm WHERE sm.map_id=s.map_id AND sm.sector_id=s.id);
}
if (flags & 256) <> 0 {
-- Stairs (special 8). Doom walks OUTWARD IN A LINE from the tagged
-- sector: at each step it takes the first two-sided line whose neighbour has
-- the same floor flat, and raises that sector another 8 units.
--
-- Each step is an ordinary upward floor mover with its own target: vanilla
-- spawns one floormove_t per step too, and they arrive staggered, which is
-- what makes a staircase appear to build itself.
WITH RECURSIVE
events AS (
  SELECT e.map_id,e.line_id,ld.tag,
         COALESCE(d.step_height,8)::int AS step_h, COALESCE(d.speed,1) AS speed
  FROM line_special_events e JOIN linedefs ld
    ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='stairs'
  WHERE e.map_id=p_map_id
),
-- Sector adjacency, both ways, built once. Recursing straight over linedefs
-- re-joined the whole map at every level.
adj AS (
  SELECT linedef_id AS edge_id, sector_id AS a, other_id AS b
  FROM sector_adjacency WHERE map_id=p_map_id AND sector_id<>other_id
),
chain AS (
  SELECT e.map_id,e.line_id,s.id AS sector_id,s.floor_tex,0 AS step,
         (s.floor_height+e.step_h)::int AS destination,ARRAY[s.id] AS seen,
         e.step_h,e.speed
  FROM events e JOIN sectors s ON s.map_id=e.map_id AND s.tag=e.tag
  UNION ALL
  SELECT c.map_id,c.line_id,n.nid,n.ntex,c.step+1,c.destination+c.step_h,
         c.seen||n.nid,c.step_h,c.speed
  FROM chain c
  CROSS JOIN LATERAL (
    SELECT nxt.id AS nid,nxt.floor_tex AS ntex
    FROM adj JOIN sectors nxt ON nxt.map_id=p_map_id AND nxt.id=adj.b
    WHERE adj.a=c.sector_id AND nxt.floor_tex=c.floor_tex
      AND NOT (nxt.id = ANY(c.seen))
    ORDER BY adj.edge_id LIMIT 1
  ) n
  WHERE c.step<24
)
INSERT INTO sector_movers
  (map_id,sector_id,source_line_id,mover_type,plane,direction,
   bottom_height,top_height,speed,wait_tics,countdown,
   next_ceiling,next_floor,target_floor_tex,moved_this_tick)
SELECT ch.map_id,ch.sector_id,ch.line_id,'floor_raise','floor',1,
  s.floor_height,ch.destination::smallint,ch.speed,0,0,NULL,NULL,NULL,FALSE
FROM chain ch
JOIN sectors s ON s.map_id=ch.map_id AND s.id=ch.sector_id
WHERE ch.destination>s.floor_height
ON CONFLICT (map_id,sector_id) DO NOTHING;
}
if (flags & 512) <> 0 {
-- W1 light change.
WITH ev AS (
  SELECT ld.tag,d.target_light,d.light_source
  FROM line_special_events e
  JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='lights'
  WHERE e.map_id=p_map_id AND (d.light_source IS NULL OR d.light_source <> 'strobe')
),
adjacency AS (
  SELECT sector_id, other_id FROM sector_adjacency
  WHERE map_id=p_map_id AND sector_id<>other_id
),
-- EV_LightTurnOn: a fixed level, or the brightest / dimmest neighbour.
neighbour_light AS (
  SELECT a.sector_id, MAX(o.light_level) AS brightest, MIN(o.light_level) AS dimmest
  FROM adjacency a JOIN sectors o ON o.map_id=p_map_id AND o.id=a.other_id
  GROUP BY a.sector_id
),
newlight AS (
  SELECT s.id AS sector_id,
    MAX(CASE ev.light_source
          WHEN 'max_neighbor' THEN nb.brightest
          WHEN 'min_neighbor' THEN nb.dimmest
          ELSE ev.target_light END) AS lvl
  FROM ev JOIN sectors s ON s.map_id=p_map_id AND s.tag=ev.tag
  LEFT JOIN neighbour_light nb ON nb.sector_id=s.id
  GROUP BY s.id
)
UPDATE sectors s SET light_level=n.lvl
FROM newlight n
WHERE s.map_id=p_map_id AND s.id=n.sector_id AND n.lvl IS NOT NULL;

-- EV_StartLightStrobing: the tagged sectors flash like a special-3 sector
-- (SLOWDARK 35 dark, STROBEBRIGHT 5 bright) between their own level and
-- their dimmest neighbour's.
INSERT INTO sector_light_fx (map_id, sector_id, special, base_light, dark_light)
SELECT s.map_id, s.id, 3::smallint, s.light_level,
       LEAST(s.light_level, COALESCE((SELECT MIN(o.light_level)
         FROM sector_adjacency a
         JOIN sectors o ON o.map_id=a.map_id AND o.id=a.other_id
         WHERE a.map_id=s.map_id AND a.sector_id=s.id
           AND a.other_id<>s.id), 0::smallint))::smallint
FROM line_special_events e
JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
JOIN line_special_defs d ON d.special=ld.special AND d.light_source='strobe'
JOIN sectors s ON s.map_id=e.map_id AND s.tag=ld.tag
WHERE e.map_id=p_map_id
ON CONFLICT (map_id, sector_id) DO NOTHING;

UPDATE render_segs rs SET f_light=s.light_level
FROM sectors s, line_special_events e
JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='lights'
WHERE e.map_id=p_map_id
  AND s.map_id=e.map_id AND s.tag=ld.tag
  AND rs.map_id=s.map_id AND rs.fsec=s.id;

UPDATE render_segs rs SET b_light=s.light_level
FROM sectors s, line_special_events e
JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='lights'
WHERE e.map_id=p_map_id
  AND s.map_id=e.map_id AND s.tag=ld.tag
  AND rs.map_id=s.map_id AND rs.bsec=s.id;
}


if (flags & 1024) <> 0 {
-- TELEPORT (39 W1, 97 WR). Doom looks for a Thing of type 14 sitting in a
-- sector whose tag matches the line, then drops the player on it facing the
-- way that Thing faces, with momentum cleared.
--
-- Type 14 Things are invisible, so they never reach render_things and carry
-- no sector_id. Rather than run a BSP descent per destination, the
-- destination is matched to the tagged sector by its segs' bounding box and,
-- where a tag covers more than one sector, by the closest box centre. Doom's
-- teleport closets are small and hold exactly one destination, so this picks
-- the same Thing the original would.
WITH
events AS (
  SELECT e.map_id,e.line_id,e.player_thing_id,ld.tag
  FROM line_special_events e JOIN linedefs ld
    ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='teleport'
  WHERE e.map_id=p_map_id
),
tagged AS (
  SELECT e.map_id,e.line_id,e.player_thing_id,s.id AS sector_id,s.floor_height,
         MIN(rs.x1) AS min_x, MAX(rs.x1) AS max_x,
         MIN(rs.y1) AS min_y, MAX(rs.y1) AS max_y
  FROM events e
  JOIN sectors s ON s.map_id=e.map_id AND s.tag=e.tag
  JOIN render_segs rs ON rs.map_id=s.map_id AND rs.fsec=s.id
  GROUP BY e.map_id,e.line_id,e.player_thing_id,s.id,s.floor_height
),
candidates AS (
  SELECT t.*, th.id AS dest_id, th.x AS dest_x, th.y AS dest_y, th.angle AS dest_angle,
         ABS(th.x - (t.min_x+t.max_x)/2.0) + ABS(th.y - (t.min_y+t.max_y)/2.0) AS off_centre
  FROM tagged t
  JOIN things th ON th.map_id=t.map_id
  JOIN thing_role_defs tr ON tr.thing_type=th.type AND tr.is_teleport_dest
   AND th.x BETWEEN t.min_x AND t.max_x
   AND th.y BETWEEN t.min_y AND t.max_y
),
chosen AS (
  SELECT * FROM (
    SELECT c.*, ROW_NUMBER() OVER
      (PARTITION BY c.map_id,c.player_thing_id ORDER BY c.off_centre, c.dest_id) AS rn
    FROM candidates c) q
  WHERE rn=1
)
UPDATE player_state ps
SET position_x=ch.dest_x, position_y=ch.dest_y,
    -- previous_* follows the destination too: leaving it at the old position
    -- would make doom_cs_cross think the player had walked the whole way and
    -- fire every special linedef along the straight line between them.
    previous_x=ch.dest_x, previous_y=ch.dest_y,
    base_z=ch.floor_height+41.0, view_z=ch.floor_height+41.0,
    view_angle=ch.dest_angle,
    previous_view_z=ch.floor_height+41.0, previous_view_angle=ch.dest_angle,
    momentum_x=0, momentum_y=0, bob_strength=0,
    sector_id=ch.sector_id
FROM chosen ch
WHERE ps.map_id=ch.map_id AND ps.player_thing_id=ch.player_thing_id;

UPDATE things t
SET x=ps.position_x, y=ps.position_y, z=ps.view_z, angle=ps.view_angle
FROM player_state ps
WHERE t.map_id=p_map_id AND ps.map_id=t.map_id AND ps.player_thing_id=t.id
  AND EXISTS (SELECT 1 FROM line_special_events e
              JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
              JOIN line_special_defs d ON d.special=ld.special
                AND d.mechanic='teleport'
              WHERE e.map_id=t.map_id AND e.player_thing_id=t.id);
}

if (flags & 2048) <> 0 {
-- Ceilings on their own: up to the highest neighbouring ceiling (40), or down
-- to the floor (41, 43) / eight above it with a crush (44, 72).
WITH
events AS (
  SELECT e.map_id,e.line_id,ld.tag,d.height_target,d.mover_type,d.direction,d.speed,d.crush
  FROM line_special_events e JOIN linedefs ld
    ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='ceiling'
  WHERE e.map_id=p_map_id
),
adjacency AS (
  SELECT sector_id, other_id FROM sector_adjacency
  WHERE map_id=p_map_id AND sector_id<>other_id
),
targets AS (
  SELECT e.map_id,e.line_id,e.height_target,e.mover_type,e.direction,e.speed,e.crush,
    s.id AS sector_id,s.floor_height,s.ceil_height,
    MAX(other.ceil_height) AS highest_ceiling
  FROM events e JOIN sectors s ON s.map_id=e.map_id AND s.tag=e.tag
  LEFT JOIN adjacency a ON a.sector_id=s.id
  LEFT JOIN sectors other ON other.map_id=s.map_id AND other.id=a.other_id
  GROUP BY e.map_id,e.line_id,e.height_target,e.mover_type,e.direction,e.speed,e.crush,
    s.id,s.floor_height,s.ceil_height
),
targets_unique AS (
  SELECT * FROM (
    SELECT t.*,ROW_NUMBER() OVER (PARTITION BY t.map_id,t.sector_id ORDER BY t.line_id) AS rn
    FROM targets t) q WHERE rn=1
)
INSERT INTO sector_movers
  (map_id,sector_id,source_line_id,mover_type,plane,direction,
   bottom_height,top_height,speed,wait_tics,countdown,
   next_ceiling,next_floor,target_floor_tex,moved_this_tick,crush)
SELECT map_id,sector_id,line_id,mover_type,'ceiling',direction,
  CASE height_target WHEN 'highest_ceiling' THEN ceil_height
                     WHEN 'floor8' THEN floor_height+8 ELSE floor_height END,
  CASE height_target WHEN 'highest_ceiling' THEN GREATEST(ceil_height,COALESCE(highest_ceiling,ceil_height))
                     ELSE ceil_height END,
  speed,0,0,NULL,NULL,NULL,FALSE,crush
FROM targets_unique
WHERE (direction=1 AND COALESCE(highest_ceiling,ceil_height)>ceil_height)
   OR (direction=-1 AND ceil_height>CASE height_target WHEN 'floor8' THEN floor_height+8 ELSE floor_height END)
ON CONFLICT (map_id,sector_id) DO NOTHING;
}
if (flags & 4096) <> 0 {
-- Crushers: the ceiling runs between its height and eight above the floor
-- until a stop line; a stopped one resumes on the next activation.
WITH
events AS (
  SELECT e.map_id,e.line_id,ld.tag,d.speed
  FROM line_special_events e JOIN linedefs ld
    ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='crusher'
  WHERE e.map_id=p_map_id
),
targets_unique AS (
  SELECT * FROM (
    SELECT e.map_id,e.line_id,e.speed,s.id AS sector_id,s.floor_height,s.ceil_height,
      ROW_NUMBER() OVER (PARTITION BY e.map_id,s.id ORDER BY e.line_id) AS rn
    FROM events e JOIN sectors s ON s.map_id=e.map_id AND s.tag=e.tag) q
  WHERE rn=1
)
INSERT INTO sector_movers
  (map_id,sector_id,source_line_id,mover_type,plane,direction,
   bottom_height,top_height,speed,wait_tics,countdown,
   next_ceiling,next_floor,target_floor_tex,moved_this_tick,crush)
SELECT map_id,sector_id,line_id,'crusher','ceiling',-1,
  floor_height+8,ceil_height,speed,0,0,NULL,NULL,NULL,FALSE,TRUE
FROM targets_unique WHERE ceil_height>floor_height+8
ON CONFLICT (map_id,sector_id) DO UPDATE SET
  source_line_id=EXCLUDED.source_line_id,direction=-1,countdown=0,
  next_ceiling=NULL,moved_this_tick=FALSE
WHERE sector_movers.mover_type='crusher' AND sector_movers.direction=2;
}
if (flags & 8192) <> 0 {
-- EV_CeilingCrushStop / EV_StopPlat: freeze the tagged movers of that kind.
UPDATE sector_movers m
SET direction=2, moved_this_tick=FALSE
FROM line_special_events e
JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='stop'
JOIN sectors s ON s.map_id=e.map_id AND s.tag=ld.tag
WHERE e.map_id=p_map_id AND m.map_id=s.map_id AND m.sector_id=s.id
  AND m.mover_type=d.stops_mover AND m.direction<>2;
}

DELETE FROM line_special_events WHERE map_id=p_map_id;
let mut active = 0::bigint;
SELECT (SELECT count(*)::int FROM sector_movers
        WHERE map_id=p_map_id AND direction<>2) AS active_movers,
       (SELECT count(*)::int FROM line_buttons
        WHERE map_id=p_map_id AND countdown>0) AS active_buttons
{
  if active_movers > 0 { active = active + 1; }
  if active_buttons > 0 { active = active + 2; }
}
return active;
$doom$;
