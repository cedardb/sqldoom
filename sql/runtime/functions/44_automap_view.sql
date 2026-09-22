-- The automap's camera

-- A row per player, made on demand so no caller has to seed it.
CREATE OR REPLACE FUNCTION doom_automap_touch(p_map_id integer, p_player_thing_id integer)
RETURNS integer LANGUAGE cedarscript AS $doom$
INSERT INTO automap_view (map_id, player_thing_id, center_x, center_y)
SELECT p_map_id, p_player_thing_id, ps.position_x, ps.position_y
FROM player_state ps
WHERE ps.map_id = p_map_id AND ps.player_thing_id = p_player_thing_id
ON CONFLICT (map_id, player_thing_id) DO NOTHING;
return 1;
$doom$;

-- Panning drops follow mode, exactly as AM_Drawer does when you move the view.
CREATE OR REPLACE FUNCTION doom_automap_pan(p_map_id integer, p_player_thing_id integer,
                                            p_dx double precision, p_dy double precision)
RETURNS integer LANGUAGE cedarscript AS $doom$
doom_automap_touch(p_map_id, p_player_thing_id);
UPDATE automap_view av
SET center_x = CASE WHEN av.follow THEN ps.position_x ELSE av.center_x END + p_dx,
    center_y = CASE WHEN av.follow THEN ps.position_y ELSE av.center_y END + p_dy,
    follow = FALSE
FROM player_state ps
WHERE av.map_id = p_map_id AND av.player_thing_id = p_player_thing_id
  AND ps.map_id = av.map_id AND ps.player_thing_id = av.player_thing_id;
return 1;
$doom$;

CREATE OR REPLACE FUNCTION doom_automap_zoom(p_map_id integer, p_player_thing_id integer,
                                             p_factor double precision)
RETURNS integer LANGUAGE cedarscript AS $doom$
let lo = doom_const('AUTOMAP_MIN_ZOOM');
let hi = doom_const('AUTOMAP_MAX_ZOOM');
doom_automap_touch(p_map_id, p_player_thing_id);
UPDATE automap_view
SET zoom = GREATEST(lo, LEAST(hi, zoom * p_factor))::real
WHERE map_id = p_map_id AND player_thing_id = p_player_thing_id;
return 1;
$doom$;

-- 'follow', 'grid', or 'cheat' (which cycles 0 -> 1 -> 2 -> 0, as IDDT does).
-- Turning follow back on re-centres by construction: the centre is read from
-- the player while it is set.
CREATE OR REPLACE FUNCTION doom_automap_toggle(p_map_id integer, p_player_thing_id integer,
                                               p_what text)
RETURNS integer LANGUAGE cedarscript AS $doom$
doom_automap_touch(p_map_id, p_player_thing_id);
UPDATE automap_view
SET follow = CASE WHEN p_what = 'follow' THEN NOT follow ELSE follow END,
    grid   = CASE WHEN p_what = 'grid'   THEN NOT grid   ELSE grid   END,
    cheat  = CASE WHEN p_what = 'cheat'  THEN ((cheat + 1) % 3)::smallint ELSE cheat END
WHERE map_id = p_map_id AND player_thing_id = p_player_thing_id;
return 1;
$doom$;

-- The whole level, centred and padded: automap_fit_view, which was the only
-- reason a client ever needed the map's line list.
CREATE OR REPLACE FUNCTION doom_automap_fit(p_map_id integer, p_player_thing_id integer)
RETURNS integer LANGUAGE cedarscript AS $doom$
let world_height = doom_const('AUTOMAP_WORLD_HEIGHT');
let lo = doom_const('AUTOMAP_MIN_ZOOM');
let hi = doom_const('AUTOMAP_MAX_ZOOM');
doom_automap_touch(p_map_id, p_player_thing_id);
UPDATE automap_view av
SET center_x = b.cx::real, center_y = b.cy::real,
    zoom = GREATEST(lo, LEAST(hi, b.fit))::real,
    follow = FALSE
FROM (
  SELECT (MIN(LEAST(v1.x,v2.x)) + MAX(GREATEST(v1.x,v2.x))) / 2.0 AS cx,
         (MIN(LEAST(v1.y,v2.y)) + MAX(GREATEST(v1.y,v2.y))) / 2.0 AS cy,
         LEAST((320.0 - 96.0) / GREATEST(1.0, MAX(GREATEST(v1.x,v2.x)) - MIN(LEAST(v1.x,v2.x))),
               (200.0 - 144.0) / GREATEST(1.0, MAX(GREATEST(v1.y,v2.y)) - MIN(LEAST(v1.y,v2.y))))
           / (200.0 / world_height) AS fit
  FROM linedefs ld
  JOIN vertexes v1 ON v1.map_id = ld.map_id AND v1.id = ld.v1_id
  JOIN vertexes v2 ON v2.map_id = ld.map_id AND v2.id = ld.v2_id
  WHERE ld.map_id = p_map_id
) b
WHERE av.map_id = p_map_id AND av.player_thing_id = p_player_thing_id;
return 1;
$doom$;
