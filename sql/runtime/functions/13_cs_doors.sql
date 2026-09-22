CREATE OR REPLACE FUNCTION doom_cs_doors(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
-- Advance active ceiling/floor movers and repeatable switch buttons for one
-- canonical 35 Hz tic.

UPDATE line_buttons
SET just_restored=(countdown=1),countdown=GREATEST(0,countdown-1)
WHERE map_id=p_map_id AND countdown>=0;

WITH original AS (
  SELECT DISTINCT map_id,sidedef_id
  FROM line_buttons WHERE map_id=p_map_id AND just_restored
)
UPDATE sidedefs sd
SET upper_tex=COALESCE(u.original_tex,sd.upper_tex),
    mid_tex=COALESCE(m.original_tex,sd.mid_tex),
    lower_tex=COALESCE(l.original_tex,sd.lower_tex)
FROM original o
LEFT JOIN line_buttons u ON u.map_id=o.map_id AND u.sidedef_id=o.sidedef_id
  AND u.texture_part='upper'
LEFT JOIN line_buttons m ON m.map_id=o.map_id AND m.sidedef_id=o.sidedef_id
  AND m.texture_part='middle'
LEFT JOIN line_buttons l ON l.map_id=o.map_id AND l.sidedef_id=o.sidedef_id
  AND l.texture_part='lower'
WHERE sd.map_id=o.map_id AND sd.id=o.sidedef_id;

let mut any_restored = false;
SELECT EXISTS (SELECT 1 FROM line_buttons WHERE map_id=p_map_id AND just_restored) AS e
  { any_restored = e; }
if any_restored {
UPDATE render_segs rs
SET upper_tex=sd.upper_tex,mid_tex=sd.mid_tex,lower_tex=sd.lower_tex
FROM linedefs ld,sidedefs sd
WHERE rs.map_id=p_map_id AND ld.map_id=rs.map_id AND ld.id=rs.linedef_id
  AND sd.map_id=ld.map_id
  AND sd.id=CASE WHEN rs.direction=0 THEN ld.right_sd_id ELSE ld.left_sd_id END
  AND EXISTS (SELECT 1 FROM line_buttons b
    WHERE b.map_id=rs.map_id AND b.line_id=rs.linedef_id AND b.just_restored);
}

WITH
params AS (
  SELECT t.map_id,t.x::float8 AS px,t.y::float8 AS py
  FROM things t
  WHERE t.map_id=p_map_id::int AND t.id=p_player_thing_id::int
),
player_sector AS (
  SELECT doom_sector_at(p.map_id,p.px,p.py) AS sector_id FROM params p
),
occupied_sectors AS (
  SELECT DISTINCT COALESCE(ai.sector_id, rt.sector_id) AS sector_id
  FROM monster_ai ai
  JOIN params p ON ai.map_id=p.map_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND h.alive
  JOIN render_things rt ON rt.map_id=ai.map_id AND rt.thing_id=ai.thing_id
  UNION
  -- The other players of a deathmatch; this player is player_sector above.
  SELECT ps.sector_id
  FROM player_state ps JOIN params p ON ps.map_id=p.map_id
  WHERE ps.player_thing_id<>p_player_thing_id::int AND ps.alive
    AND ps.sector_id IS NOT NULL
),
current_state AS (
  SELECT m.*,s.floor_height,s.ceil_height,
    -- T_VerticalDoor asks P_ChangeSector whether anything is in the way and
    -- reverses a closing door when something is, which PIT_ChangeSector
    -- decides for every mobj in the sector. A monster
    -- standing under the door holds it open the same way a player does. Only the
    -- close-and-wait door refuses to reverse.
    -- Close-and-stay doors, ceilings coming down and crushers do not go back
    -- up for an obstacle.
    CASE WHEN m.plane='ceiling' AND m.direction=-1
          AND m.mover_type NOT IN ('door_close_open','door_close','crusher','ceiling_lower')
          AND (ps.sector_id=m.sector_id OR occ.sector_id IS NOT NULL)
         THEN 1 ELSE m.direction END AS move_direction
  FROM sector_movers m JOIN params p ON p.map_id=m.map_id
  JOIN sectors s ON s.map_id=m.map_id AND s.id=m.sector_id
  LEFT JOIN player_sector ps ON TRUE
  LEFT JOIN occupied_sectors occ ON occ.sector_id=m.sector_id
  WHERE m.direction<>2
),
-- Vanilla moves a plane in 16.16 fixed point, so PLATSPEED/2 advances it half
-- a map unit a tic. Heights here are whole units, so spend what the speed
-- affords this tic and carry the rest: a 0.5 mover steps one unit every other
-- tic, which averages the speed vanilla runs at.
stepped AS (
  SELECT c.*,
    TRUNC(c.speed + c.move_carry)::smallint AS step_units,
    (c.speed + c.move_carry) - TRUNC(c.speed + c.move_carry) AS carry_out
  FROM current_state c
),
motion AS (
  SELECT c.*,
    CASE WHEN c.plane='ceiling' THEN
      CASE c.move_direction WHEN 1 THEN LEAST(c.top_height,c.ceil_height+c.step_units)
        WHEN -1 THEN GREATEST(c.bottom_height,c.ceil_height-c.step_units)
        ELSE c.ceil_height END
      ELSE c.ceil_height END::smallint AS computed_ceiling,
    CASE WHEN c.plane='floor' THEN
      CASE c.move_direction WHEN 1 THEN LEAST(c.top_height,c.floor_height+c.step_units)
        WHEN -1 THEN GREATEST(c.bottom_height,c.floor_height-c.step_units)
        ELSE c.floor_height END
      ELSE c.floor_height END::smallint AS computed_floor
  FROM stepped c
),
next_state AS (
  SELECT m.*,
    CASE
      WHEN m.move_direction=1
        AND ((m.plane='ceiling' AND m.computed_ceiling>=m.top_height)
          OR (m.plane='floor' AND m.computed_floor>=m.top_height))
        THEN CASE WHEN m.mover_type IN ('door_raise','door_manual_raise','platform_perpetual')
                  THEN 0
                  -- a crusher turns straight round at the top
                  WHEN m.mover_type='crusher' THEN -1
                  ELSE 2 END
      WHEN m.move_direction=0 AND m.countdown<=1
        THEN CASE WHEN m.mover_type IN ('platform','door_close_open') THEN 1
                  -- a perpetual platform heads back the way it did not come
                  WHEN m.mover_type='platform_perpetual'
                    THEN CASE WHEN m.floor_height>=m.top_height THEN -1 ELSE 1 END
                  ELSE -1 END
      WHEN m.move_direction=-1
        AND ((m.plane='ceiling' AND m.computed_ceiling<=m.bottom_height)
          OR (m.plane='floor' AND m.computed_floor<=m.bottom_height))
        THEN CASE WHEN m.mover_type IN ('platform','door_close_open','platform_perpetual')
                  THEN 0
                  WHEN m.mover_type='crusher' THEN 1
                  ELSE 2 END
      ELSE m.move_direction END::smallint AS computed_direction,
    CASE
      WHEN m.move_direction=1 AND m.mover_type IN ('door_raise','door_manual_raise','platform_perpetual')
        AND ((m.plane='ceiling' AND m.computed_ceiling>=m.top_height)
          OR (m.plane='floor' AND m.computed_floor>=m.top_height)) THEN m.wait_tics
      WHEN m.move_direction=-1 AND m.mover_type IN ('platform','platform_perpetual')
        AND m.computed_floor<=m.bottom_height THEN m.wait_tics
      -- The 30-second hold starts when the ceiling reaches the floor.
      WHEN m.move_direction=-1 AND m.mover_type='door_close_open'
        AND m.computed_ceiling<=m.bottom_height THEN m.wait_tics
      WHEN m.move_direction=0 THEN GREATEST(0,m.countdown-1)
      ELSE m.countdown END AS computed_countdown
  FROM motion m
)
UPDATE sector_movers mover
SET direction=n.computed_direction,countdown=n.computed_countdown,
    -- A mover that has arrived or is waiting starts its next leg whole.
    move_carry=CASE WHEN n.computed_direction IN (0,2) THEN 0 ELSE n.carry_out END,
    next_ceiling=n.computed_ceiling,next_floor=n.computed_floor,
    moved_this_tick=(n.computed_ceiling<>n.ceil_height
      OR n.computed_floor<>n.floor_height)
FROM next_state n
WHERE mover.map_id=n.map_id AND mover.sector_id=n.sector_id;

UPDATE sectors s SET ceil_height=m.next_ceiling
FROM sector_movers m
WHERE m.map_id=p_map_id AND s.map_id=m.map_id AND s.id=m.sector_id
  AND m.plane='ceiling' AND m.moved_this_tick;

UPDATE sectors s
SET floor_height=m.next_floor,
    floor_tex=CASE WHEN m.direction=2 AND m.target_floor_tex IS NOT NULL
                   THEN m.target_floor_tex ELSE s.floor_tex END
FROM sector_movers m
WHERE m.map_id=p_map_id AND s.map_id=m.map_id AND s.id=m.sector_id
  AND m.plane='floor' AND m.moved_this_tick;

-- PIT_ChangeSector's crush: a crushing mover that has just closed the gap
-- below a Thing's height hurts it for 10 every fourth tic.
UPDATE thing_health h
SET health=h.health-10, alive=h.health-10>0
FROM sector_movers m
JOIN sectors s ON s.map_id=m.map_id AND s.id=m.sector_id
JOIN render_things rt ON rt.map_id=m.map_id AND rt.sector_id=m.sector_id
JOIN things t ON t.map_id=rt.map_id AND t.id=rt.thing_id
JOIN thing_combat_defs d ON d.thing_type=t.type AND NOT d.explodes
JOIN player_state pc ON pc.map_id=m.map_id AND pc.player_thing_id=p_player_thing_id::int
WHERE m.map_id=p_map_id AND m.crush AND m.moved_this_tick
  AND ((m.plane='ceiling' AND m.direction=-1) OR (m.plane='floor' AND m.direction=1))
  AND h.map_id=t.map_id AND h.thing_id=t.id AND h.alive
  AND s.ceil_height-s.floor_height < d.height
  AND pc.level_tics % 4 = 0;

UPDATE player_state ps
SET armor=ps.armor-d.saved,
    armor_class=CASE WHEN ps.armor-d.saved<=0 THEN 0 ELSE ps.armor_class END,
    health=GREATEST(0,ps.health-(10-d.saved)),
    damage_count=LEAST(100,ps.damage_count+(10-d.saved)),
    pain_face_tics=12,
    alive=(ps.health-(10-d.saved))>0,
    killer_id=CASE WHEN (ps.health-(10-d.saved))<=0 THEN -1 ELSE ps.killer_id END
FROM (
  SELECT ps2.map_id, ps2.player_thing_id,
         LEAST(ps2.armor, CASE ps2.armor_class WHEN 2 THEN 5 WHEN 1 THEN 3 ELSE 0 END) AS saved
  FROM sector_movers m
  JOIN sectors s ON s.map_id=m.map_id AND s.id=m.sector_id
  JOIN player_state ps2 ON ps2.map_id=m.map_id AND ps2.sector_id=m.sector_id
  WHERE m.map_id=p_map_id AND m.crush AND m.moved_this_tick
    AND ((m.plane='ceiling' AND m.direction=-1) OR (m.plane='floor' AND m.direction=1))
    AND s.ceil_height-s.floor_height<56
    AND ps2.alive AND NOT ps2.god_mode AND ps2.invuln_tics<=0
    AND ps2.level_tics % 4 = 0
) d
WHERE ps.map_id=d.map_id AND ps.player_thing_id=d.player_thing_id;

UPDATE render_segs rs
SET f_floor=s.floor_height,f_ceil=s.ceil_height,
    f_ceil_tex=s.ceil_tex,f_light=s.light_level
FROM sectors s JOIN sector_movers m
  ON m.map_id=s.map_id AND m.sector_id=s.id
WHERE rs.map_id=p_map_id AND rs.map_id=s.map_id
  AND m.moved_this_tick AND rs.fsec=s.id;

UPDATE render_segs rs
SET b_floor=s.floor_height,b_ceil=s.ceil_height,
    b_ceil_tex=s.ceil_tex,b_light=s.light_level
FROM sectors s JOIN sector_movers m
  ON m.map_id=s.map_id AND m.sector_id=s.id
WHERE rs.map_id=p_map_id AND rs.map_id=s.map_id
  AND m.moved_this_tick AND rs.bsec=s.id;
$doom$;
