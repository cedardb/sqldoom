CREATE OR REPLACE FUNCTION doom_cs_thing_physics(p_map_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
-- P_XYMovement for Things.
--
-- Doom carries every mobj by its momentum each tic and multiplies it by
-- FRICTION (0xe800/65536 = 0.90625) once it is on the ground (nothing slows a
-- thing that is in the air, z > floorz: a shoved cacodemon drifts); a step that runs
-- into something stops dead rather than sliding along it, because P_TryMove
-- refuses the move and P_XYMovement zeroes the momentum for anything that is
-- not a missile or a skull. STOPSPEED (0x1000/65536 = 0.0625) is where it
-- gives up and calls the thing still.
--
-- Only things with momentum are touched, so an ordinary tic reads a handful of
-- rows and writes none: the shove from P_DamageMobj is the only thing that
-- ever sets it, and it dies away within a couple of seconds.
let mut moved = 0;
let friction = doom_const('FRICTION');
let stop_speed = doom_const('STOPSPEED');
let max_step = doom_const('MAXSTEP');

let mut any_moving = false;
SELECT EXISTS (
  SELECT 1 FROM things
  WHERE map_id = p_map_id AND (ABS(mom_x) > stop_speed OR ABS(mom_y) > stop_speed)) AS e
  { any_moving = e; }
if any_moving {
WITH
moving AS (
  SELECT t.id, t.x::float8 AS x, t.y::float8 AS y,
         t.mom_x::float8 AS mx, t.mom_y::float8 AS my,
         cd.radius::float8 AS radius,
         -- MF_SKULLFLY: steps do not stop it and it keeps its speed until
         -- it hits something
         cd.skull_fly AS skull,
         cd.floats AND COALESCE(h.alive, FALSE) AND t.z > sec.floor_height AS airborne
  FROM things t
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  JOIN render_things rt ON rt.map_id = t.map_id AND rt.thing_id = t.id
  LEFT JOIN thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id
  LEFT JOIN monster_ai ai ON ai.map_id = t.map_id AND ai.thing_id = t.id
  JOIN sectors sec ON sec.map_id = t.map_id AND sec.id = COALESCE(ai.sector_id, rt.sector_id)
  WHERE t.map_id = p_map_id
    AND (ABS(t.mom_x) > stop_speed OR ABS(t.mom_y) > stop_speed)
    -- Players move through doom_cs_move; their Thing only mirrors it.
    AND NOT EXISTS (SELECT 1 FROM player_state ps
                    WHERE ps.map_id = t.map_id AND ps.player_thing_id = t.id)
),
-- P_TryMove's line check: the step is refused if it crosses a one-sided line,
-- an explicitly blocking one, or a step too tall to climb. Bounded by the two
-- bounding boxes overlapping, the same way the monster mover bounds its own.
wall_hit AS (
  SELECT m.id, TRUE AS hit
  FROM moving m
  JOIN linedef_geom ld ON ld.map_id = p_map_id
  LEFT JOIN sectors fr ON fr.map_id = ld.map_id AND fr.id = ld.fsec
  LEFT JOIN sectors bk ON bk.map_id = ld.map_id AND bk.id = ld.bsec
  WHERE (ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR (ld.flags & 1) <> 0
      OR (NOT m.skull AND fr.floor_height IS NOT NULL AND bk.floor_height IS NOT NULL
          AND ABS(fr.floor_height - bk.floor_height) > max_step))
    AND LEAST(ld.x1,ld.x2) <= GREATEST(m.x, m.x+m.mx) + m.radius
    AND GREATEST(ld.x1,ld.x2) >= LEAST(m.x, m.x+m.mx) - m.radius
    AND LEAST(ld.y1,ld.y2) <= GREATEST(m.y, m.y+m.my) + m.radius
    AND GREATEST(ld.y1,ld.y2) >= LEAST(m.y, m.y+m.my) - m.radius
    AND ((m.x+m.mx - ld.x1)*(ld.y2-ld.y1) - (m.y+m.my - ld.y1)*(ld.x2-ld.x1))
      * ((m.x - ld.x1)*(ld.y2-ld.y1) - (m.y - ld.y1)*(ld.x2-ld.x1)) < 0
    AND ((ld.x1 - m.x)*m.my - (ld.y1 - m.y)*m.mx)
      * ((ld.x2 - m.x)*m.my - (ld.y2 - m.y)*m.mx) < 0
  GROUP BY m.id
),
-- PIT_CheckThing: and it stops on anything solid standing where it is going.
thing_hit AS (
  SELECT m.id, TRUE AS hit
  FROM moving m
  JOIN things o ON o.map_id = p_map_id AND o.id <> m.id
  JOIN thing_combat_defs od ON od.thing_type = o.type
  JOIN thing_health oh ON oh.map_id = o.map_id AND oh.thing_id = o.id
   AND oh.alive
  WHERE ABS(o.x - (m.x+m.mx)) < od.radius + m.radius
    AND ABS(o.y - (m.y+m.my)) < od.radius + m.radius
  GROUP BY m.id
),
step AS (
  SELECT m.*, COALESCE(w.hit,FALSE) OR COALESCE(th.hit,FALSE) AS blocked
  FROM moving m
  LEFT JOIN wall_hit w ON w.id = m.id
  LEFT JOIN thing_hit th ON th.id = m.id
)
-- The geometry above runs in float8; the write-back adds and multiplies the
-- real columns directly, so the row body carries no casts or range checks.
UPDATE things t
SET x = CASE WHEN s.blocked THEN t.x ELSE t.x + t.mom_x END,
    y = CASE WHEN s.blocked THEN t.y ELSE t.y + t.mom_y END,
    -- FRICTION once it has moved; a blocked step loses its momentum outright,
    -- a skull or an airborne thing keeps it.
    mom_x = CASE WHEN s.blocked THEN 0 WHEN s.skull OR s.airborne THEN t.mom_x ELSE t.mom_x * friction END,
    mom_y = CASE WHEN s.blocked THEN 0 WHEN s.skull OR s.airborne THEN t.mom_y ELSE t.mom_y * friction END
FROM step s
WHERE t.map_id = p_map_id AND t.id = s.id;
}

-- Anything below STOPSPEED is standing still; zero it so the statement above
-- stops finding it.
UPDATE things
SET mom_x = 0, mom_y = 0
WHERE map_id = p_map_id
  AND ABS(mom_x) <= stop_speed AND ABS(mom_y) <= stop_speed
  AND (mom_x <> 0 OR mom_y <> 0);

return moved;
$doom$;
