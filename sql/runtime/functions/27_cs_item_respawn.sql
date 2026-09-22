-- P_RespawnSpecials, deathmatch 2.0 (-altdeath): a special that was picked
-- up comes back 30 seconds later where it stood, with the item fog and its
-- sound.
CREATE OR REPLACE FUNCTION doom_cs_item_respawn(p_map_id integer, p_player_thing_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
let mut alt = false;
let item_respawn_tics = doom_const('ITEM_RESPAWN_TICS');
let dropped_base = doom_const('DROPPED_THING_ID_BASE');
let fog_base = doom_const('ITEM_FOG_EFFECT_ID_BASE');
let tic_span = doom_const('EFFECT_ID_TIC_SPAN');
SELECT m.altdeath AS a FROM mp_match m WHERE m.map_id = p_map_id AND m.state = 'playing' { alt = a; }
if alt {
-- Everything taken and not yet queued: the pickup stage inserted the row this
-- tic, so the 30 seconds start now.
INSERT INTO item_respawns (map_id, thing_id, respawn_tic)
SELECT pu.map_id, pu.thing_id, (ps.level_tics + item_respawn_tics)::bigint
FROM picked_up_items pu
JOIN things t ON t.map_id = pu.map_id AND t.id = pu.thing_id
JOIN player_state ps ON ps.map_id = pu.map_id AND ps.player_thing_id = p_player_thing_id
-- A monster's drop is gone for good; only a real map item comes back.
WHERE pu.map_id = p_map_id AND pu.thing_id < dropped_base
  AND EXISTS (SELECT 1 FROM pickup_defs d WHERE d.thing_type = t.type)
  AND NOT EXISTS (SELECT 1 FROM item_respawns r WHERE r.map_id = pu.map_id AND r.thing_id = pu.thing_id);

let mut due = -1;
SELECT r.thing_id AS t
FROM item_respawns r
JOIN player_state ps ON ps.map_id = r.map_id AND ps.player_thing_id = p_player_thing_id
WHERE r.map_id = p_map_id AND ps.level_tics >= r.respawn_tic
ORDER BY r.respawn_tic, r.thing_id LIMIT 1 { due = t; }
if due >= 0 {
  -- The item fog (IFOG) at the spot, and DSITMBK from it.
  INSERT INTO world_effects (map_id, effect_id, effect_type, x, y, z, sector_id, age)
  SELECT t.map_id, fog_base::bigint + t.id::bigint * tic_span
                   + (ps.level_tics % tic_span),
         'ifog', t.x, t.y, s.floor_height, rt.sector_id, 0
  FROM things t
  JOIN render_things rt ON rt.map_id = t.map_id AND rt.thing_id = t.id
  JOIN sectors s ON s.map_id = rt.map_id AND s.id = rt.sector_id
  JOIN player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = p_player_thing_id
  WHERE t.map_id = p_map_id AND t.id = due
  ON CONFLICT (map_id, effect_id) DO NOTHING;

  INSERT INTO sound_events (map_id, event_key, level_tic, sound_name, source_thing_id, source_x, source_y)
  SELECT t.map_id, 'itemrespawn:' || t.id::text || ':' || ps.level_tics::text, ps.level_tics,
         'DSITMBK', t.id, t.x, t.y
  FROM things t
  JOIN player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = p_player_thing_id
  WHERE t.map_id = p_map_id AND t.id = due
  ON CONFLICT (map_id, event_key) DO NOTHING;

  DELETE FROM picked_up_items WHERE map_id = p_map_id AND thing_id = due;
  DELETE FROM item_respawns WHERE map_id = p_map_id AND thing_id = due;
}
}
return 1;
$doom$;
