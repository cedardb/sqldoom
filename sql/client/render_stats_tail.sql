-- Counting projection spliced onto sql/renderer.sql at its @stats-cut marker
-- (see doom_sql.prepare_render_stats). Every number the debug overlay shows is
-- therefore counted inside the very pipeline that produced the frame, not
-- estimated from a copy that could drift.
render_stats AS (
  SELECT
    (SELECT count(*) FROM bsp_order)         AS subsectors,
    (SELECT count(*) FROM segs_with_verts)   AS segs,
    (SELECT count(*) FROM clamped_spans)     AS wall_spans,
    (SELECT count(*) FROM fragments)         AS wall_px,
    (SELECT count(*) FROM plane_fragments)   AS plane_px,
    (SELECT count(*) FROM sprite_fragments)  AS sprite_px,
    (SELECT count(*) FROM psprite_resolved)  AS psprite_px,
    (SELECT count(*) FROM ranked_fragments)  AS fragments_ranked,
    (SELECT count(*) FROM resolved)          AS pixels_resolved,
    (SELECT count(*) FROM view_holes)        AS holes,
    -- The two halves of the finished framebuffer: the 3-D view and the
    -- status bar, which is composited by the same query.
    (SELECT count(*) FROM view_colored)      AS view_px,
    (SELECT count(*) FROM ui_colored)        AS ui_px,
    -- Culling: how much of the map's BSP the frustum test threw away, and
    -- which interior nodes the walk actually descended into. The node list is
    -- a few dozen integers, small enough to ship every sample.
    (SELECT count(*) FROM visible_children)             AS bsp_children,
    (SELECT count(*) FROM visible_children WHERE keep)  AS bsp_kept,
    (SELECT array_agg(ssector_id) FROM bsp_order)       AS bsp_subsectors,
    -- The sprite pipeline's own upstream. Note it does NOT hang off the BSP
    -- walk: thing_view scans render_things and transforms by the camera, where
    -- vanilla calls R_AddSprites per subsector during traversal. So a thing in
    -- a subsector the walk never reached is still projected here, and only
    -- thing_projected's depth/side reject removes it.
    (SELECT count(*) FROM thing_view)        AS things_in_view,
    (SELECT count(*) FROM thing_bounds)      AS things_drawn
)
-- Column ORDER matters: doom_sql.fetch_render_stats zips the leading scalars
-- against RENDER_STATS_FIELDS positionally and then reads the subsector array
-- at exactly that offset, so every new scalar goes BEFORE bsp_subsectors and
-- the array stays last.
SELECT subsectors, segs, wall_spans, wall_px, plane_px, sprite_px,
       psprite_px, fragments_ranked, pixels_resolved, holes, view_px, ui_px,
       bsp_children, bsp_kept, things_in_view, things_drawn, bsp_subsectors
FROM render_stats;
