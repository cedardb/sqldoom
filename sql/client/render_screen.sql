-- Composite a full-screen title / menu / intermission frame.
--
-- Returns exactly what sql/renderer.sql returns -- one 320x200 RGB bytea in
-- row-major order -- so the client blits a menu and a level with the same
-- code. The patch machinery is the status bar's (ui_patches +
-- ui_patch_pixels): same decode, same transparency mask, same COLORMAP.
--
-- All state lives in screen_state. The one parameter is the client's frame
-- counter, used only for the skull's blink: deriving it from a stored counter
-- would mean a write per displayed frame for a purely cosmetic animation.
WITH
state AS (SELECT * FROM screen_state WHERE id = 0),

-- Layer 0: whatever fills the screen behind everything else.
background AS (
  SELECT 0 AS layer,
    CASE s.screen
      WHEN 'title' THEN 'TITLEPIC'
      -- M_DrawReadThis1/2. On the retail IWAD the second page is CREDIT
      -- rather than HELP2, which is not in it.
      WHEN 'help1' THEN 'HELP1'
      WHEN 'help2' THEN 'CREDIT'
      WHEN 'intermission' THEN
        CASE s.inter_episode WHEN 1 THEN 'WIMAP0' WHEN 2 THEN 'WIMAP1'
                             WHEN 3 THEN 'WIMAP2' ELSE 'INTERPIC' END
      -- The finale's text page is a tiled flat, not a patch, and is laid in
      -- by finale_flat below; only the ending picture comes from here.
      WHEN 'finale' THEN
        (SELECT f.patch FROM finale_defs f WHERE f.episode = s.finale_episode)
      ELSE 'TITLEPIC'
    END AS patch,
    0 AS x, 0 AS y
  FROM state s
  WHERE (s.screen <> 'finale' OR s.finale_stage <> 0)
    -- Episode 3's ending is not one picture but the bunny scroll below.
    AND NOT (s.screen = 'finale' AND s.finale_episode = 3)
),

-- F_BunnyScroll: PFUB2 fills the screen, then after 230 tics PFUB1 scrolls in
-- from the left over 640 tics (half a pixel a tic); from tic 1130 THE END is
-- stamped in the middle and from 1180 its letters flicker in one by one.
bunny AS (
  SELECT s.finale_count AS c,
         LEAST(320, GREATEST(0, 320 - (s.finale_count - 230) / 2)) AS scrolled
  FROM state s
  WHERE s.screen = 'finale' AND s.finale_stage <> 0 AND s.finale_episode = 3
),
bunny_layers AS (
  SELECT 0 AS layer, 'PFUB1'::text AS patch, -b.scrolled AS x, 0 AS y FROM bunny b WHERE b.scrolled < 320
  UNION ALL
  SELECT 0, 'PFUB2', 320 - b.scrolled, 0 FROM bunny b WHERE b.scrolled > 0
  UNION ALL
  SELECT 1, 'END' || LEAST(6, GREATEST(0, (b.c - 1180) / 5))::text, 108, 68
  FROM bunny b WHERE b.c >= 1130
),

-- ---------------------------------------------------------------- --
-- Finale (f_finale.c). F_TextWrite erases the screen to a tiled 64x64
-- flat and then types the episode's text out at TEXTSPEED, 3 tics a
-- character after a ten-tic lead-in.
-- ---------------------------------------------------------------- --
-- Flats are stored as raw palette indices rather than as patches, so this
-- one reaches the framebuffer directly instead of going through
-- ui_patch_pixels: the tile is an index into the lump, 64 bytes a row.
finale_flat AS (
  SELECT gx.x, gy.y,
         get_byte(fl.palette_indices, ((gy.y % 64) * 64) + (gx.x % 64))
           AS palette_index
  FROM state s
  JOIN finale_defs f ON f.episode = s.finale_episode
  JOIN flat_textures fl ON fl.name = f.flat
  CROSS JOIN generate_series(0, 319) AS gx(x)
  CROSS JOIN generate_series(0, 199) AS gy(y)
  WHERE s.screen = 'finale' AND s.finale_stage = 0
),
finale_text AS (
  SELECT s.finale_count, gs.i,
         substring(f.story_text FROM gs.i FOR 1) AS ch
  FROM state s
  JOIN finale_defs f ON f.episode = s.finale_episode
  CROSS JOIN LATERAL generate_series(1, length(f.story_text)) AS gs(i)
  WHERE s.screen = 'finale' AND s.finale_stage = 0
),
finale_metrics AS (
  SELECT t.*,
         -- cy is driven by how many newlines came before, so the line number
         -- is also what partitions the running width below.
         COALESCE(SUM(CASE WHEN t.ch = chr(10) THEN 1 ELSE 0 END) OVER (
           ORDER BY t.i ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
           AS line_no,
         -- A space advances 4 and draws nothing; an unmapped character also
         -- advances 4, so the rest of the line does not shift left.
         CASE WHEN t.ch = chr(10) THEN 0
              WHEN t.ch = ' ' THEN 4
              ELSE COALESCE((SELECT p.width FROM ui_patches p
                             WHERE p.name = 'STCFN'
                                || LPAD(ASCII(UPPER(t.ch))::text, 3, '0')), 4)
         END AS w
  FROM finale_text t
),
-- Placed over every character, visible or not, and only then filtered down to
-- the ones typed so far: the spaces have to stay in the running sum or every
-- word after the first would slide left.
finale_placed AS (
  SELECT m.*,
         10 + COALESCE(SUM(m.w) OVER (
           PARTITION BY m.line_no ORDER BY m.i
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS x,
         10 + 11 * m.line_no AS y
  FROM finale_metrics m
),
finale_layers AS (
  SELECT 1 AS layer,
         'STCFN' || LPAD(ASCII(UPPER(p.ch))::text, 3, '0') AS patch,
         p.x, p.y
  FROM finale_placed p
  WHERE p.i <= GREATEST(0, (p.finale_count - 10) / 3)
    AND p.ch <> chr(10) AND p.ch <> ' '
    -- F_TextWrite stops the line rather than wrapping it.
    AND p.x + p.w <= 320
),

-- Headings and logos: not selectable, so they are kept apart from the items.
decor AS (
  SELECT 1 AS layer, d.patch, d.x, d.y
  FROM state s JOIN menu_decor d ON d.screen = s.screen
),

items AS (
  SELECT 1 AS layer, m.patch, m.x, m.y
  FROM state s JOIN menu_items m ON m.screen = s.screen
  -- Load/Save lines carry no patch: they are a border plus text, and exist in
  -- menu_items only so the cursor has a row to sit on.
  WHERE m.patch IS NOT NULL
),

-- The skull sits 32px left of the item column and 5px above its line, and
-- alternates every 8 tics, exactly as M_Drawer does.
cursor_layer AS (
  SELECT 2 AS layer,
    CASE WHEN (($1::int) / 8) % 2 = 0 THEN 'M_SKULL1' ELSE 'M_SKULL2' END AS patch,
    m.x - 32 AS x, m.y - 5 AS y
  FROM state s
  JOIN menu_items m ON m.screen = s.screen AND m.idx = s.cursor_index
),

-- ---------------------------------------------------------------- --
-- Intermission (wi_stuff.c, single player). Doom's own coordinates:
--   WI_TITLEY 2, SP_STATSX 50, SP_STATSY 50, SP_TIMEX 16, SP_TIMEY 168.
-- ---------------------------------------------------------------- --
inter_state AS (SELECT * FROM state WHERE screen = 'intermission'),

-- Metrics Doom reads off the patches themselves rather than hard-coding.
metrics AS (
  SELECT
    (SELECT height FROM ui_patches WHERE name='WINUM0') AS num_h,
    (SELECT width  FROM ui_patches WHERE name='WINUM0') AS num_w,
    (SELECT width  FROM ui_patches WHERE name='WIPCNT') AS pct_w
),
level_name AS (
  SELECT s.*, 'WILV' || (s.inter_episode - 1)::text
                     || (s.inter_level - 1)::text AS patch
  FROM inter_state s
),
next_name AS (
  SELECT s.*, 'WILV' || (s.inter_episode - 1)::text
                     || (s.inter_next - 1)::text AS patch
  FROM inter_state s
),
-- "<level> / finished", both centred, then the stat block.
inter_headings AS (
  SELECT 1 AS layer, ln.patch, (320 - p.width) / 2 AS x, 2 AS y
  FROM level_name ln JOIN ui_patches p ON p.name = ln.patch
  UNION ALL
  SELECT 1, 'WIF', (320 - f.width) / 2, 2 + (5 * p.height) / 4
  FROM level_name ln
  JOIN ui_patches p ON p.name = ln.patch
  CROSS JOIN ui_patches f
  WHERE f.name = 'WIF'
),
inter_labels AS (
  SELECT 1 AS layer, 'WIOSTK'::text AS patch, 50 AS x, 50 AS y FROM inter_state
  UNION ALL SELECT 1,'WIOSTI', 50, 50 + (3*m.num_h)/2 FROM inter_state, metrics m
  UNION ALL SELECT 1,'WISCRT2',50, 50 + 2*((3*m.num_h)/2) FROM inter_state, metrics m
  UNION ALL SELECT 1,'WITIME', 16, 168 FROM inter_state
  UNION ALL SELECT 1,'WIPAR', 176, 168 FROM inter_state
  -- The percent sign sits AT the right margin; the number ends there.
  UNION ALL SELECT 1,'WIPCNT',270, 50 FROM inter_state
  UNION ALL SELECT 1,'WIPCNT',270, 50 + (3*m.num_h)/2 FROM inter_state, metrics m
  UNION ALL SELECT 1,'WIPCNT',270, 50 + 2*((3*m.num_h)/2) FROM inter_state, metrics m
),
-- Every number on the screen as a right-aligned run of characters.
inter_runs AS (
  SELECT COALESCE(s.kills_pct,0)::text AS txt, 270 AS right_x, 50 AS y
  FROM inter_state s
  UNION ALL
  SELECT COALESCE(s.items_pct,0)::text, 270, 50 + (3*m.num_h)/2
  FROM inter_state s, metrics m
  UNION ALL
  SELECT COALESCE(s.secrets_pct,0)::text, 270, 50 + 2*((3*m.num_h)/2)
  FROM inter_state s, metrics m
  UNION ALL
  -- Doom shows level time and par as M:SS.
  SELECT (COALESCE(s.time_secs,0)/60)::text || ':' ||
         LPAD((COALESCE(s.time_secs,0)%60)::text, 2, '0'), 144, 168
  FROM inter_state s
  UNION ALL
  SELECT (COALESCE(s.par_secs,0)/60)::text || ':' ||
         LPAD((COALESCE(s.par_secs,0)%60)::text, 2, '0'), 304, 168
  FROM inter_state s
),
run_chars AS (
  SELECT r.txt, r.right_x, r.y, gs.i,
         substring(r.txt FROM gs.i FOR 1) AS ch
  FROM inter_runs r
  CROSS JOIN LATERAL generate_series(1, length(r.txt)) AS gs(i)
),
run_glyphs AS (
  SELECT rc.*,
         CASE rc.ch WHEN ':' THEN 'WICOLON' WHEN '-' THEN 'WIMINUS'
                    ELSE 'WINUM' || rc.ch END AS patch
  FROM run_chars rc
),
-- Right-align with per-glyph widths: the colon is narrower than a digit, so
-- a fixed pitch would drift. Walking the widths from the right gives each
-- glyph's offset from the margin.
run_placed AS (
  SELECT g.patch, g.y,
         g.right_x - SUM(p.width) OVER (
           PARTITION BY g.txt, g.right_x, g.y
           ORDER BY g.i DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
         ) AS x
  FROM run_glyphs g JOIN ui_patches p ON p.name = g.patch
),
inter_layers AS (
  SELECT layer, patch, x, y FROM inter_headings
  UNION ALL SELECT layer, patch, x, y FROM inter_labels
  UNION ALL SELECT 1, patch, x, y FROM run_placed
),

-- ---------------------------------------------------------------- --
-- Load / Save. M_DrawSaveLoadBorder: a left cap at x-8, 24 centre tiles
-- every 8px, a right cap; the name is written at (x, y) in the HU font.
-- LoadDef/SaveDef sit at x=80, y=54 with LINEHEIGHT 16.
-- ---------------------------------------------------------------- --
slot_rows AS (
  SELECT m.idx, m.x, m.y
  FROM state s JOIN menu_items m ON m.screen = s.screen
  WHERE s.screen IN ('load','save')
),
slot_border AS (
  SELECT 1 AS layer, 'M_LSLEFT'::text AS patch, r.x - 8 AS x, r.y + 7 AS y
  FROM slot_rows r
  UNION ALL
  SELECT 1, 'M_LSCNTR', r.x + 8 * t.n, r.y + 7
  FROM slot_rows r CROSS JOIN generate_series(0, 23) AS t(n)
  UNION ALL
  SELECT 1, 'M_LSRGHT', r.x + 8 * 24, r.y + 7
  FROM slot_rows r
),
-- Doom uppercases every string it draws, because the font has no lowercase.
text_runs AS (
  SELECT UPPER(COALESCE(ss.name, '')) AS txt, r.x, r.y
  FROM slot_rows r
  LEFT JOIN save_slots ss ON ss.slot = r.idx
),
text_chars AS (
  SELECT t.txt, t.x, t.y, gs.i, substring(t.txt FROM gs.i FOR 1) AS ch
  FROM text_runs t
  CROSS JOIN LATERAL generate_series(1, GREATEST(1, length(t.txt))) AS gs(i)
  WHERE length(t.txt) > 0
),
text_glyphs AS (
  SELECT tc.*,
         CASE WHEN tc.ch = ' ' THEN NULL
              ELSE 'STCFN' || LPAD(ASCII(tc.ch)::text, 3, '0') END AS patch,
         -- A space advances 4px and draws nothing, as M_WriteText does; an
         -- unmapped character is skipped but still advances, so the rest of
         -- the string does not shift left.
         CASE WHEN tc.ch = ' ' THEN 4
              ELSE COALESCE((SELECT p.width FROM ui_patches p
                             WHERE p.name = 'STCFN'
                                || LPAD(ASCII(tc.ch)::text, 3, '0')), 4)
         END AS w
  FROM text_chars tc
),
text_placed AS (
  SELECT g.patch, g.y,
         g.x + COALESCE(SUM(g.w) OVER (
           PARTITION BY g.txt, g.x, g.y ORDER BY g.i
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS x
  FROM text_glyphs g
),
saveload_layers AS (
  SELECT layer, patch, x, y FROM slot_border
  UNION ALL SELECT 2, patch, x, y FROM text_placed WHERE patch IS NOT NULL
),

layers AS (
  SELECT layer, patch, x, y FROM background
  UNION ALL SELECT layer, patch, x, y FROM decor
  UNION ALL SELECT layer, patch, x, y FROM items
  UNION ALL SELECT layer, patch, x, y FROM cursor_layer
  UNION ALL SELECT layer, patch, x, y FROM inter_layers
  UNION ALL SELECT layer, patch, x, y FROM saveload_layers
  UNION ALL SELECT layer, patch, x, y FROM finale_layers
  UNION ALL SELECT layer, patch, x, y FROM bunny_layers
),

-- From here down this mirrors ui_layer_patches -> ui_pixels -> ui_resolved.
layer_patches AS (
  SELECT l.layer, l.patch,
         l.x - p.left_offset AS dest_x,
         l.y - p.top_offset  AS dest_y
  FROM layers l JOIN ui_patches p ON p.name = l.patch
),
pixels AS (
  SELECT lp.layer, lp.dest_x + px.dx AS x, lp.dest_y + px.dy AS y,
         px.palette_index
  FROM layer_patches lp
  JOIN ui_patch_pixels px ON px.name = lp.patch
  WHERE lp.dest_x + px.dx BETWEEN 0 AND 319
    AND lp.dest_y + px.dy BETWEEN 0 AND 199
  -- Layer 0 for the finale's background: already palette indices, so it joins
  -- the pixel stream here rather than at the patch stage.
  UNION ALL
  SELECT 0 AS layer, x, y, palette_index FROM finale_flat
),
resolved AS (
  SELECT x, y, ARG_MAX(palette_index, layer) AS palette_index
  FROM pixels GROUP BY x, y
),
colored AS (
  SELECT r.x, r.y, COALESCE(cm.rgb, '\x000000'::bytea) AS rgb
  FROM resolved r
  LEFT JOIN colormap_rgb cm
    -- Palette 0: the title, menu and intermission screens are composited at
    -- the normal palette. colormap_rgb is keyed by (pal, level, index) since
    -- the damage/pickup flashes were added, and a join that leaves pal out
    -- matches all fourteen palettes -- fourteen rows per pixel, a framebuffer
    -- fourteen times too long, and a screen the client refuses to blit.
    ON cm.pal = 0 AND cm.level = 0 AND cm.palette_index = r.palette_index
),
-- A background that does not cover the screen would otherwise drop rows and
-- shorten the framebuffer; fill anything uncovered with black.
holes AS (
  SELECT gx.x, gy.y, '\x000000'::bytea AS rgb
  FROM generate_series(0, 319) AS gx(x)
  CROSS JOIN generate_series(0, 199) AS gy(y)
  WHERE NOT EXISTS (SELECT 1 FROM colored c WHERE c.x = gx.x AND c.y = gy.y)
),
framebuffer AS (
  SELECT x, y, rgb FROM colored
  UNION ALL SELECT x, y, rgb FROM holes
),
frame_rows AS (
  SELECT y, string_agg(rgb, ''::bytea ORDER BY x) AS row_rgb
  FROM framebuffer GROUP BY y
)
SELECT string_agg(row_rgb, ''::bytea ORDER BY y) AS frame_rgb FROM frame_rows;
