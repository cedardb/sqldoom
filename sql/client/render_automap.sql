-- Composite a full-screen automap frame.
--
-- Returns exactly what sql/renderer.sql and sql/client/render_screen.sql
-- return -- one 320x200 RGB bytea in row-major order -- so the client blits
-- the map with the same code path as the world and the menus, and Python is
-- left holding no drawing logic at all.
--
-- Params: $1 map_id, $2 player_thing_id.
WITH
settings AS (
  SELECT $1::int AS map_id, $2::int AS player_thing_id,
         (CASE WHEN COALESCE(av.follow, TRUE) THEN ps.position_x
               ELSE av.center_x END)::float8 AS cx,
         (CASE WHEN COALESCE(av.follow, TRUE) THEN ps.position_y
               ELSE av.center_y END)::float8 AS cy,
         ((200.0 / (SELECT value FROM doom_constants WHERE name='AUTOMAP_WORLD_HEIGHT'))
           * COALESCE(av.zoom, 1.0))::float8 AS scale,
         ps.power_map AS reveal_all,
         -- am_map.c keeps one `cheating` counter that AM_Drawer reads twice:
         -- any non-zero value opens up AM_drawWalls, and only 2 also calls
         -- AM_drawThings.
         (COALESCE(av.cheat, 0) > 0) AS cheat,
         (COALESCE(av.cheat, 0) = 2) AS show_things,
         COALESCE(av.grid, FALSE) AS grid,
         320::int AS w, 200::int AS h
  FROM player_state ps
  LEFT JOIN automap_view av ON av.map_id = ps.map_id
   AND av.player_thing_id = ps.player_thing_id
  WHERE ps.map_id = $1::int AND ps.player_thing_id = $2::int
),
-- am_map.c's own cascade and its own palette constants:
--   REDS   176  a one-sided wall, and anything that should read as solid
--   BROWNS  64  a step in the floor between the two sides
--   YELLOWS 231 a step in the ceiling
--   GRAYS    96 two-sided with neither -- cheat only, so never drawn here
--   GRAYS+3  99 revealed by the computer map but not yet walked
--   WHITE   209 the player marker
-- Ordering matters: a teleporter and a secret door are drawn as walls even
-- though they are two-sided, so a secret reads as solid until it opens.
drawn_lines AS (
  SELECT
    v1.x::float8 AS x1, v1.y::float8 AS y1,
    v2.x::float8 AS x2, v2.y::float8 AS y2,
    CASE
      -- Handed to the player by the computer map rather than walked: Doom
      -- draws these dim, so the map still shows what you have actually been
      -- to.
      -- IDDT shows the level as built, so an unwalked line is drawn in
      -- full colour rather than the computer map's dim grey.
      WHEN NOT seen.ok AND NOT s.cheat THEN 99
      WHEN ls.sector_id IS NULL OR rs.sector_id IS NULL THEN 176
      -- WALLCOLORS + WALLRANGE/2, a shade off plain red.
      WHEN ld.special = 39 THEN 184
      WHEN (ld.flags & 32) <> 0 THEN 176
      WHEN rsec.floor_height <> lsec.floor_height THEN 64
      WHEN rsec.ceil_height <> lsec.ceil_height THEN 231
      -- Two-sided with no step: TSWALLCOLORS, which AM_drawWalls emits
      -- only when cheating.
      WHEN s.cheat THEN 96
      ELSE NULL
    END AS palette_index
  FROM settings s
  JOIN linedefs ld ON ld.map_id = s.map_id
  JOIN vertexes v1 ON v1.map_id=ld.map_id AND v1.id=ld.v1_id
  JOIN vertexes v2 ON v2.map_id=ld.map_id AND v2.id=ld.v2_id
  LEFT JOIN sidedefs rs ON rs.map_id=ld.map_id AND rs.id=ld.right_sd_id
  LEFT JOIN sidedefs ls ON ls.map_id=ld.map_id AND ls.id=ld.left_sd_id
  LEFT JOIN sectors rsec ON rsec.map_id=ld.map_id AND rsec.id=rs.sector_id
  LEFT JOIN sectors lsec ON lsec.map_id=ld.map_id AND lsec.id=ls.sector_id
  CROSS JOIN LATERAL (
    SELECT EXISTS (SELECT 1 FROM mapped_lines m
                   WHERE m.map_id = ld.map_id AND m.line_id = ld.id) AS ok
  ) seen
  -- LINE_NEVERSEE. Mappers set it on construction geometry they do not want
  -- on the map, and AM_drawWalls skips it even for lines already seen --
  -- unless IDDT is on, which shows everything.
  WHERE (s.cheat OR (ld.flags & 128) = 0)
    AND (seen.ok OR s.reveal_all OR s.cheat)
),
classified AS (
  SELECT x1, y1, x2, y2, palette_index FROM drawn_lines
  WHERE palette_index IS NOT NULL
),
-- World to screen. y is flipped: north is up.
projected AS (
  SELECT c.palette_index,
         s.w/2.0 + (c.x1 - s.cx) * s.scale AS ax,
         s.h/2.0 - (c.y1 - s.cy) * s.scale AS ay,
         s.w/2.0 + (c.x2 - s.cx) * s.scale AS bx,
         s.h/2.0 - (c.y2 - s.cy) * s.scale AS by
  FROM classified c CROSS JOIN settings s
),
-- The player marker, am_map.c's player_arrow[]: seven segments in units of
-- R = 8*PLAYERRADIUS/7, rotated by the view angle. Keeping the shape as data
-- means the arrow is the same barbed one Doom draws rather than a stand-in.
arrow_shape AS (
  SELECT * FROM (VALUES
    (-0.875,  0.0  ,  1.0  ,  0.0  ),
    ( 1.0  ,  0.0  ,  0.5  ,  0.25 ),
    ( 1.0  ,  0.0  ,  0.5  , -0.25 ),
    (-0.875,  0.0  , -1.125,  0.25 ),
    (-0.875,  0.0  , -1.125, -0.25 ),
    (-0.625,  0.0  , -0.875,  0.25 ),
    (-0.625,  0.0  , -0.875, -0.25 )
  ) AS a(lx1, ly1, lx2, ly2)
),
arrow AS (
  SELECT 209 AS palette_index,
         s.w/2.0 + ((t.x + r.rr*(a.lx1*COS(r.ang) - a.ly1*SIN(r.ang))) - s.cx) * s.scale AS ax,
         s.h/2.0 - ((t.y + r.rr*(a.lx1*SIN(r.ang) + a.ly1*COS(r.ang))) - s.cy) * s.scale AS ay,
         s.w/2.0 + ((t.x + r.rr*(a.lx2*COS(r.ang) - a.ly2*SIN(r.ang))) - s.cx) * s.scale AS bx,
         s.h/2.0 - ((t.y + r.rr*(a.lx2*SIN(r.ang) + a.ly2*COS(r.ang))) - s.cy) * s.scale AS by
  FROM settings s
  JOIN things t ON t.map_id = s.map_id AND t.id = s.player_thing_id
  CROSS JOIN arrow_shape a
  CROSS JOIN LATERAL (
    SELECT RADIANS(t.angle::float8) AS ang, (8.0*16.0/7.0)::float8 AS rr
  ) r
),
-- The second press of IDDT adds AM_drawThings: every mobj still in the level
-- as a thin triangle pointing the way it faces, in GREENS. thintriangle_guy[]
-- is written in units of R = FRACUNIT and AM_drawThings scales it by the 16
-- map units below, so this is the same 16-unit triangle Doom draws -- a fixed
-- size on the map, unrelated to the actor's real radius.
thing_shape AS (
  SELECT * FROM (VALUES
    (-0.5, -0.7,  1.0,  0.0),
    ( 1.0,  0.0, -0.5,  0.7),
    (-0.5,  0.7, -0.5, -0.7)
  ) AS a(lx1, ly1, lx2, ly2)
),
-- AM_drawThings walks the sector thinglists, so it draws exactly the mobjs
-- that exist right now: the skill filter and the multiplayer-only flag decided
-- at spawn, collected pickups gone, corpses still there. render_things is
-- already that set for everything with a sprite.
mobjs AS (
  SELECT t.x::float8 AS x, t.y::float8 AS y, t.angle::float8 AS angle
  FROM settings s
  JOIN render_things rt ON rt.map_id = s.map_id
  JOIN things t ON t.map_id = rt.map_id AND t.id = rt.thing_id
  LEFT JOIN game_tic_commands gc
    ON gc.map_id = s.map_id AND gc.player_thing_id = s.player_thing_id
  LEFT JOIN picked_up_items pu
    ON pu.map_id = rt.map_id AND pu.thing_id = rt.thing_id
  LEFT JOIN monster_ai ai ON ai.map_id = rt.map_id AND ai.thing_id = rt.thing_id
  WHERE s.show_things
    AND (t.flags & COALESCE(gc.skill_bit, 2)) <> 0
    AND (t.flags & 16) = 0
    AND pu.thing_id IS NULL
    -- A barrel's death state runs off the end of the state table, so vanilla
    -- removes the mobj outright; every other corpse stays and keeps drawing.
    AND NOT (EXISTS (SELECT 1 FROM thing_combat_defs cd
                     WHERE cd.thing_type = t.type AND cd.explodes)
             AND ai.state = 'dead')
  UNION ALL
  -- P_SpawnMapThing turns the type-1 start into the player mobj instead of
  -- spawning a sprite for it, so render_things has no row for the player --
  -- but the player is a mobj in a sector thinglist like any other, so
  -- AM_drawThings draws a triangle for him too, on top of his own white
  -- arrow, because AM_Drawer calls it after AM_drawPlayers.
  SELECT t.x::float8, t.y::float8, t.angle::float8
  FROM settings s
  JOIN things t ON t.map_id = s.map_id AND t.id = s.player_thing_id
  WHERE s.show_things
),
thing_marks AS (
  SELECT 112 AS palette_index,
         s.w/2.0 + ((m.x + r.rr*(a.lx1*COS(r.ang) - a.ly1*SIN(r.ang))) - s.cx) * s.scale AS ax,
         s.h/2.0 - ((m.y + r.rr*(a.lx1*SIN(r.ang) + a.ly1*COS(r.ang))) - s.cy) * s.scale AS ay,
         s.w/2.0 + ((m.x + r.rr*(a.lx2*COS(r.ang) - a.ly2*SIN(r.ang))) - s.cx) * s.scale AS bx,
         s.h/2.0 - ((m.y + r.rr*(a.lx2*SIN(r.ang) + a.ly2*COS(r.ang))) - s.cy) * s.scale AS by
  FROM settings s
  CROSS JOIN mobjs m
  CROSS JOIN thing_shape a
  CROSS JOIN LATERAL (
    SELECT RADIANS(m.angle) AS ang, 16.0::float8 AS rr
  ) r
),
-- AM_drawGrid. Doom rules the map off in MAPBLOCKUNITS -- the 128-unit
-- blockmap cell -- in GRIDCOLORS, which is GRAYS + GRAYSRANGE/2. The lines
-- start on a multiple of 128 rather than on the view edge, so the grid stays
-- still while the map slides under it. Every one of them is generated across
-- the whole visible span and then thrown at the same clipper as the walls.
grid_span AS (
  SELECT s.cx - (s.w/2.0)/s.scale AS x0, s.cx + (s.w/2.0)/s.scale AS x1,
         s.cy - (s.h/2.0)/s.scale AS y0, s.cy + (s.h/2.0)/s.scale AS y1
  FROM settings s WHERE s.grid
),
grid_lines AS (
  SELECT 104 AS palette_index,
         s.w/2.0 + (g.k*128.0 - s.cx) * s.scale AS ax,
         s.h/2.0 - (v.y0 - s.cy) * s.scale AS ay,
         s.w/2.0 + (g.k*128.0 - s.cx) * s.scale AS bx,
         s.h/2.0 - (v.y1 - s.cy) * s.scale AS by
  FROM settings s CROSS JOIN grid_span v
  CROSS JOIN LATERAL generate_series(CEIL(v.x0/128.0)::int,
                                     FLOOR(v.x1/128.0)::int) AS g(k)
  UNION ALL
  SELECT 104,
         s.w/2.0 + (v.x0 - s.cx) * s.scale,
         s.h/2.0 - (g.k*128.0 - s.cy) * s.scale,
         s.w/2.0 + (v.x1 - s.cx) * s.scale,
         s.h/2.0 - (g.k*128.0 - s.cy) * s.scale
  FROM settings s CROSS JOIN grid_span v
  CROSS JOIN LATERAL generate_series(CEIL(v.y0/128.0)::int,
                                     FLOOR(v.y1/128.0)::int) AS g(k)
),
segments AS (
  SELECT palette_index, ax, ay, bx, by FROM projected
  UNION ALL SELECT palette_index, ax, ay, bx, by FROM arrow
  UNION ALL SELECT palette_index, ax, ay, bx, by FROM thing_marks
  UNION ALL SELECT palette_index, ax, ay, bx, by FROM grid_lines
),
-- Liang-Barsky against the screen rectangle. Without this a long line at a
-- high zoom would still be stepped over its whole length, nearly all of it
-- off screen; clipping first bounds the step count to the screen diagonal.
clipped AS (
  SELECT g.palette_index, g.ax, g.ay, g.bx, g.by, g.dx, g.dy,
         GREATEST(0.0, t0.v) AS t_lo, LEAST(1.0, t1.v) AS t_hi
  FROM (
    SELECT sg.*, (sg.bx-sg.ax) AS dx, (sg.by-sg.ay) AS dy FROM segments sg
  ) g
  CROSS JOIN settings s
  CROSS JOIN LATERAL (
    SELECT GREATEST(
      CASE WHEN g.dx > 0 THEN (0.0 - g.ax)/g.dx
           WHEN g.dx < 0 THEN (s.w - 1.0 - g.ax)/g.dx ELSE 0.0 END,
      CASE WHEN g.dy > 0 THEN (0.0 - g.ay)/g.dy
           WHEN g.dy < 0 THEN (s.h - 1.0 - g.ay)/g.dy ELSE 0.0 END) AS v
  ) t0
  CROSS JOIN LATERAL (
    SELECT LEAST(
      CASE WHEN g.dx > 0 THEN (s.w - 1.0 - g.ax)/g.dx
           WHEN g.dx < 0 THEN (0.0 - g.ax)/g.dx ELSE 1.0 END,
      CASE WHEN g.dy > 0 THEN (s.h - 1.0 - g.ay)/g.dy
           WHEN g.dy < 0 THEN (0.0 - g.ay)/g.dy ELSE 1.0 END) AS v
  ) t1
  -- Reject the fully-off-screen ones, and the degenerate zero-length ones.
  WHERE (g.dx <> 0 OR g.dy <> 0)
    AND GREATEST(0.0, t0.v) <= LEAST(1.0, t1.v)
),
-- One pixel per step along the clipped span, the step count being the longer
-- of the two axis extents so the line is continuous.
line_pixels AS (
  SELECT c.palette_index,
         ROUND(c.ax + c.dx * (c.t_lo + (c.t_hi - c.t_lo) * g.i / n.steps))::int AS x,
         ROUND(c.ay + c.dy * (c.t_lo + (c.t_hi - c.t_lo) * g.i / n.steps))::int AS y
  FROM clipped c
  CROSS JOIN LATERAL (
    SELECT GREATEST(1.0, CEIL(GREATEST(
      ABS(c.dx * (c.t_hi - c.t_lo)), ABS(c.dy * (c.t_hi - c.t_lo)))))::float8 AS steps
  ) n
  CROSS JOIN LATERAL generate_series(0, n.steps::int) AS g(i)
),
coloured AS (
  SELECT p.x, p.y, p.palette_index,
         -- The marker draws over the level; a walked line draws over one the
         -- computer map merely handed over.
         -- AM_Drawer's own order: walls, then the player arrow, then the
         -- IDDT triangles last of all.
         -- AM_Drawer's order: the grid first, so everything paints over it.
         CASE p.palette_index
           WHEN 112 THEN 10 WHEN 209 THEN 9 WHEN 99 THEN 0
           WHEN 104 THEN -1 ELSE 1
         END AS layer
  FROM line_pixels p
  CROSS JOIN settings s
  WHERE p.x BETWEEN 0 AND s.w - 1 AND p.y BETWEEN 0 AND s.h - 1
),
resolved AS (
  -- layer first, then the palette index as a tiebreak. ARG_MAX on the layer
  -- alone leaves ties -- two segments of different colours meeting on one
  -- pixel at the same layer -- to be broken arbitrarily, which made the same
  -- view render differently from one frame to the next. Vanilla has no ties
  -- to break: AM_drawWalls paints in list order and the last writer wins.
  SELECT x, y, ARG_MAX(palette_index, layer * 256 + palette_index)
           AS palette_index
  FROM coloured GROUP BY x, y
),
lit AS (
  SELECT r.x, r.y, COALESCE(cm.rgb, '\x000000'::bytea) AS rgb
  FROM resolved r
  LEFT JOIN colormap_rgb cm
    ON cm.pal = 0 AND cm.level = 0 AND cm.palette_index = r.palette_index
),
holes AS (
  SELECT sx.x, sy.y, '\x000000'::bytea AS rgb
  FROM settings s
  CROSS JOIN LATERAL generate_series(0, s.w - 1) AS sx(x)
  CROSS JOIN LATERAL generate_series(0, s.h - 1) AS sy(y)
  WHERE NOT EXISTS (SELECT 1 FROM lit l WHERE l.x = sx.x AND l.y = sy.y)
),
framebuffer AS (
  SELECT x, y, rgb FROM lit UNION ALL SELECT x, y, rgb FROM holes
),
packed AS (
  -- Same assembly as sql/renderer.sql: eight pixels per row packed by a hash
  -- aggregate, so the ordered bytea string_agg concatenates 8000 pieces
  -- rather than 64000.
  SELECT y, x/8 AS g,
         MAX(CASE WHEN x%8=0 THEN rgb END)||MAX(CASE WHEN x%8=1 THEN rgb END)||MAX(CASE WHEN x%8=2 THEN rgb END)||MAX(CASE WHEN x%8=3 THEN rgb END)||MAX(CASE WHEN x%8=4 THEN rgb END)||MAX(CASE WHEN x%8=5 THEN rgb END)||MAX(CASE WHEN x%8=6 THEN rgb END)||MAX(CASE WHEN x%8=7 THEN rgb END) AS px
  FROM framebuffer
  GROUP BY y, x/8
)
SELECT string_agg(px, ''::bytea ORDER BY y, g) AS frame_rgb FROM packed;
