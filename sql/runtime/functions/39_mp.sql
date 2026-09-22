-- Deathmatch. Two players on one map, driven by one server process that runs
-- doom_run_mp_tic at 35 Hz; each client renders its own view with the normal
-- renderer and pushes its input into mp_inputs. Every stage is the same stage
-- single-player runs -- the per-player ones are just called once per player,
-- the world ones once -- so the two modes cannot drift apart.

-- ---------------------------------------------------------------------------
-- G_DeathMatchSpawnPlayer: put the player on a random deathmatch start that no
-- other player is standing on, with the vanilla reborn loadout.
CREATE OR REPLACE FUNCTION doom_mp_respawn(p_map_id integer, p_player_thing_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
let respawn_fog_base = doom_const('PLAYER_RESPAWN_EFFECT_ID_BASE');
let tic_span = doom_const('EFFECT_ID_TIC_SPAN');
WITH me AS (
  SELECT level_tics FROM player_state
  WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id
),
others AS (
  SELECT t.x::float8 AS x, t.y::float8 AS y
  FROM player_state ps
  JOIN things t ON t.map_id=ps.map_id AND t.id=ps.player_thing_id
  WHERE ps.map_id=p_map_id AND ps.player_thing_id<>p_player_thing_id AND ps.alive
),
starts AS (
  -- Thing type 11 is a deathmatch start. P_CheckSpot would refuse one with a
  -- body in it; a 64-unit box around every other live player stands in.
  SELECT t.id, t.x, t.y, t.angle,
         ROW_NUMBER() OVER (ORDER BY t.id) AS rn, COUNT(*) OVER () AS n
  FROM things t
  WHERE t.map_id=p_map_id AND t.type=11
    AND NOT EXISTS (SELECT 1 FROM others o
                    WHERE ABS(o.x-t.x)<64.0 AND ABS(o.y-t.y)<64.0)
),
pick AS (
  SELECT s.* FROM starts s CROSS JOIN me
  WHERE s.rn = (doom_prandom(p_player_thing_id, me.level_tics, 41) % s.n) + 1
)
UPDATE things t
SET x=pk.x, y=pk.y, angle=pk.angle, mom_x=0, mom_y=0
FROM pick pk
WHERE t.map_id=p_map_id AND t.id=p_player_thing_id;

-- G_PlayerReborn: full health, no armour, fist and pistol with 50 bullets.
-- The frag count is the one thing that survives.
UPDATE player_state ps
SET health=100, alive=TRUE, armor=0, armor_class=0, backpack=FALSE,
    ammo_bullets=50, ammo_shells=0, ammo_rockets=0, ammo_cells=0,
    key_blue=FALSE, key_yellow=FALSE, key_red=FALSE,
    radsuit_tics=0, invis_tics=0, light_amp_tics=0, invuln_tics=0,
    berserk=FALSE, power_map=FALSE, god_mode=FALSE, noclip=FALSE,
    pain_face_tics=0, damage_count=0, bonus_count=0,
    death_tics=0, killer_id=NULL, sprite_frame='A',
    momentum_x=0, momentum_y=0, momentum_z=0, bob_strength=0
WHERE ps.map_id=p_map_id AND ps.player_thing_id=p_player_thing_id;

DELETE FROM player_weapon_owned
WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id;

INSERT INTO player_weapon_owned (map_id, player_thing_id, weapon_id)
VALUES (p_map_id, p_player_thing_id, 1), (p_map_id, p_player_thing_id, 2);

DELETE FROM player_weapons
WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id;

INSERT INTO player_weapons (map_id, player_thing_id)
VALUES (p_map_id, p_player_thing_id);

-- The death cue is latched per player so it plays once per death; a new life
-- needs it released.
DELETE FROM sound_events
WHERE map_id=p_map_id AND event_key='plr-death:'||p_player_thing_id::text;

doom_spawn_player(p_map_id, p_player_thing_id);

-- The teleport fog at the new spot, and its sound.
INSERT INTO world_effects (map_id, effect_id, effect_type, x, y, z, sector_id, age)
SELECT ps.map_id, respawn_fog_base::bigint + ps.player_thing_id::bigint * tic_span
                  + (ps.level_tics % tic_span),
       'tfog', ps.position_x, ps.position_y, s.floor_height, ps.sector_id, 0
FROM player_state ps
JOIN sectors s ON s.map_id=ps.map_id AND s.id=ps.sector_id
WHERE ps.map_id=p_map_id AND ps.player_thing_id=p_player_thing_id
ON CONFLICT (map_id, effect_id) DO NOTHING;

INSERT INTO sound_events
  (map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y)
SELECT ps.map_id,'respawn:'||ps.player_thing_id::text||':'||ps.level_tics::text,
       ps.level_tics,'DSTELEPT',ps.player_thing_id,ps.position_x,ps.position_y
FROM player_state ps
WHERE ps.map_id=p_map_id AND ps.player_thing_id=p_player_thing_id
ON CONFLICT (map_id,event_key) DO NOTHING;
return 1;
$doom$;

-- ---------------------------------------------------------------------------
-- Start a two-player deathmatch on a map: the single-player reset, a second
-- player on the player-2 start's Thing, -nomonsters, and both players placed
-- on deathmatch starts.
CREATE OR REPLACE FUNCTION doom_mp_vacate_all(p_map_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
UPDATE player_state ps
SET alive=FALSE, health=0, killer_id=NULL, death_tics=36,
    momentum_x=0, momentum_y=0, momentum_z=0
FROM mp_players mp
WHERE mp.map_id=ps.map_id AND mp.player_thing_id=ps.player_thing_id
  AND mp.map_id=p_map_id;
UPDATE mp_players SET role_name=NULL, last_seen=NULL, display_name=NULL WHERE map_id=p_map_id;
DELETE FROM mp_join_requests WHERE map_id=p_map_id;
return 1;
$doom$;

-- Hand back every slot whose holder has said nothing for p_seconds: a closed
-- tab, a dropped connection. Returns how many were freed.
CREATE OR REPLACE FUNCTION doom_mp_start(p_map_id integer, p_skill integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
doom_reset_stage(p_map_id, p_skill);

-- One match at a time: every slot of every map is cleared.
DELETE FROM mp_players;

-- Slot n is the player-n start's Thing: the row the player IS, wherever the
-- deathmatch start puts it. Slots open free; api_join claims them.
INSERT INTO mp_players (map_id, slot, player_thing_id, skill)
SELECT p_map_id, t.type, MIN(t.id), p_skill
FROM things t WHERE t.map_id=p_map_id AND t.type IN (1,2,3,4)
GROUP BY t.type;

-- doom_reset_stage created the player rows for the type-1 start; the same
-- rows, same shape, for slots 2 to 4.
INSERT INTO player_weapons (map_id, player_thing_id)
SELECT map_id, player_thing_id FROM mp_players WHERE map_id=p_map_id AND slot>=2;

INSERT INTO player_weapon_owned (map_id, player_thing_id, weapon_id)
SELECT mp.map_id, mp.player_thing_id, w.weapon_id
FROM mp_players mp CROSS JOIN (VALUES (1), (2)) AS w (weapon_id)
WHERE mp.map_id=p_map_id AND mp.slot>=2;

INSERT INTO player_state (
  map_id,player_thing_id,health,alive,ammo_bullets,
  previous_x,previous_y,position_x,position_y,base_z,view_z,view_angle
)
SELECT t.map_id,t.id,100,TRUE,50,t.x,t.y,t.x,t.y,t.z,t.z,t.angle
FROM mp_players mp
JOIN things t ON t.map_id=mp.map_id AND t.id=mp.player_thing_id
WHERE mp.map_id=p_map_id AND mp.slot>=2;

-- -nomonsters, unless the match keeps them: everything that would count as
-- a kill is not spawned. Barrels stay. A Thing without health or AI would
-- still be drawn standing there by the renderer, so it is hidden the way a
-- taken item is.
let mut monsters = false;
SELECT m.monsters AS x FROM mp_match m { monsters = x; }
if NOT monsters {
INSERT INTO picked_up_items (map_id, thing_id)
SELECT h.map_id, h.thing_id
FROM thing_health h
JOIN things t ON t.map_id=h.map_id AND t.id=h.thing_id
JOIN thing_combat_defs d ON d.thing_type=t.type AND d.counts_kill
WHERE h.map_id=p_map_id
ON CONFLICT (map_id, thing_id) DO NOTHING;

DELETE FROM monster_ai ai
USING things t, thing_combat_defs d
WHERE ai.map_id=p_map_id AND t.map_id=ai.map_id AND t.id=ai.thing_id
  AND d.thing_type=t.type AND d.counts_kill;

DELETE FROM thing_health h
USING things t, thing_combat_defs d
WHERE h.map_id=p_map_id AND t.map_id=h.map_id AND t.id=h.thing_id
  AND d.thing_type=t.type AND d.counts_kill;
}

DELETE FROM mp_inputs WHERE map_id=p_map_id;

-- Every slot gets a reborn loadout at a deathmatch start, then lies dead and
-- free: no input ever reaches an unclaimed slot, so P_DeathThink never
-- respawns it, and the claim (api_join, via the next tic) respawns it fresh.
let mut q1 = NULL::int; let mut q2 = NULL::int; let mut q3 = NULL::int; let mut q4 = NULL::int;
SELECT player_thing_id FROM mp_players WHERE map_id=p_map_id AND slot=1 { q1 = player_thing_id; }
SELECT player_thing_id FROM mp_players WHERE map_id=p_map_id AND slot=2 { q2 = player_thing_id; }
SELECT player_thing_id FROM mp_players WHERE map_id=p_map_id AND slot=3 { q3 = player_thing_id; }
SELECT player_thing_id FROM mp_players WHERE map_id=p_map_id AND slot=4 { q4 = player_thing_id; }
if q1 IS NOT NULL { doom_mp_respawn(p_map_id, q1); }
if q2 IS NOT NULL { doom_mp_respawn(p_map_id, q2); }
if q3 IS NOT NULL { doom_mp_respawn(p_map_id, q3); }
if q4 IS NOT NULL { doom_mp_respawn(p_map_id, q4); }
doom_mp_vacate_all(p_map_id);
let mut n = 0;
SELECT count(*)::int AS c FROM mp_players WHERE map_id=p_map_id { n = c; }
return n;
$doom$;

-- ---------------------------------------------------------------------------
-- The PLAY sprite frame the other client draws this player with. Vanilla runs
-- the player mobj through S_PLAY_RUN1-4 (A-D, 4 tics each) while moving,
-- S_PLAY_ATK1/2 (E, then F with the muzzle flash) when firing, S_PLAY_PAIN (G)
-- for 8 tics after a hit, S_PLAY_DIE1-7 (H-N, 10 tics each) or, gibbed,
-- S_PLAY_XDIE1-9 (O-W, 5 tics each).
CREATE OR REPLACE FUNCTION doom_cs_player_pose(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
UPDATE player_state ps
SET sprite_frame = (CASE
  WHEN NOT ps.alive THEN
    CASE WHEN ps.health < -100
         THEN CHR(ASCII('O') + LEAST(8, ps.death_tics / 5))
         ELSE CHR(ASCII('H') + LEAST(6, ps.death_tics / 10)) END
  WHEN ps.pain_face_tics >= 9 THEN 'G'
  WHEN pw.flash_seq_index IS NOT NULL THEN 'F'
  WHEN pw.state NOT IN ('ready','up','down') THEN 'E'
  WHEN ps.bob_strength > 0.05 OR ABS(ps.momentum_x) + ABS(ps.momentum_y) > 0.1
    THEN SUBSTRING('ABCD' FROM ((ps.level_tics / 4) % 4)::int + 1 FOR 1)
  ELSE 'A' END)::char(1)
FROM player_weapons pw
WHERE ps.map_id=p_map_id AND ps.player_thing_id=p_player_thing_id
  AND pw.map_id=ps.map_id AND pw.player_thing_id=ps.player_thing_id;
$doom$;

-- ---------------------------------------------------------------------------
-- P_KillMobj's frag bookkeeping, once per tic over everyone who died in it.
-- Thing ids start at 0, so the world is -1 and every non-negative killer is a
-- player.
-- The damage statements leave the killer in player_state.killer_id: another
-- player's thing id, or -1 for the world (a barrel, a floor, a monster).
-- Killing yourself or dying to the world costs a frag, as in vanilla.
CREATE OR REPLACE FUNCTION doom_mp_frags(p_map_id integer)
LANGUAGE cedarscript AS $doom$
UPDATE player_state k
SET frags = k.frags + 1,
    message = 'YOU FRAGGED ' || COALESCE(vs.display_name, 'PLAYER ' || vs.slot::text),
    message_tics = 140
FROM player_state v
JOIN mp_players vs ON vs.map_id=v.map_id AND vs.player_thing_id=v.player_thing_id
WHERE v.map_id=p_map_id AND NOT v.alive AND v.killer_id IS NOT NULL
  AND v.killer_id >= 0 AND v.killer_id <> v.player_thing_id
  AND k.map_id=v.map_id AND k.player_thing_id=v.killer_id;

UPDATE player_state v
SET frags = v.frags - CASE WHEN v.killer_id = v.player_thing_id OR v.killer_id < 0
                           THEN 1 ELSE 0 END,
    message = CASE WHEN v.killer_id = v.player_thing_id THEN 'YOU KILLED YOURSELF'
                   WHEN v.killer_id < 0 THEN 'YOU DIED'
                   ELSE COALESCE(ks.display_name, 'PLAYER ' || ks.slot::text) || ' FRAGGED YOU' END,
    message_tics = 140,
    killer_id = NULL
FROM mp_players ks
WHERE v.map_id=p_map_id AND NOT v.alive AND v.killer_id IS NOT NULL
  AND ks.map_id=v.map_id
  AND ks.player_thing_id = CASE WHEN v.killer_id >= 0 THEN v.killer_id
                                ELSE v.player_thing_id END;
$doom$;

-- A slot with nobody behind it. The player is left dead with its frags: the
-- respawn on the next claim gives it a fresh body, and nothing can score off
-- a corpse.
CREATE OR REPLACE FUNCTION doom_mp_reap(p_map_id integer, p_seconds integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
DELETE FROM mp_waiting WHERE EXTRACT(EPOCH FROM (now() - last_seen)) > 5;
let mut freed = 0;
-- Nobody can heartbeat between maps (the API is quiet then), so nobody is
-- idle either.
let mut playing = false;
SELECT (m.state = 'playing') AS x FROM mp_match m { playing = x; }
if playing {
SELECT count(*)::int AS n FROM mp_players mp
WHERE mp.map_id=p_map_id AND mp.role_name IS NOT NULL
  AND (mp.last_seen IS NULL OR EXTRACT(EPOCH FROM (now() - mp.last_seen)) > p_seconds)
{ freed = n; }
}
if freed > 0 {
  UPDATE player_state ps
  SET alive=FALSE, health=0, killer_id=NULL, death_tics=36,
      momentum_x=0, momentum_y=0, momentum_z=0
  FROM mp_players mp
  WHERE mp.map_id=ps.map_id AND mp.player_thing_id=ps.player_thing_id
    AND mp.map_id=p_map_id AND mp.role_name IS NOT NULL
    AND (mp.last_seen IS NULL OR EXTRACT(EPOCH FROM (now() - mp.last_seen)) > p_seconds);
  UPDATE mp_players SET role_name=NULL, last_seen=NULL, display_name=NULL
  WHERE map_id=p_map_id AND role_name IS NOT NULL
    AND (last_seen IS NULL OR EXTRACT(EPOCH FROM (now() - last_seen)) > p_seconds);
}
return freed;
$doom$;

-- One referee per map. TRUE when this caller now holds the map: no heartbeat
-- yet, or the last one is older than p_stale_seconds (a referee that died).
CREATE OR REPLACE FUNCTION doom_mp_referee_claim(p_map_id integer, p_stale_seconds integer) RETURNS boolean
LANGUAGE cedarscript AS $doom$
let mut busy = false;
SELECT EXISTS(SELECT 1 FROM mp_referee r WHERE r.map_id=p_map_id
              AND EXTRACT(EPOCH FROM (now() - r.heartbeat)) < p_stale_seconds) AS e { busy = e; }
if NOT busy {
  DELETE FROM mp_referee WHERE map_id=p_map_id;
  INSERT INTO mp_referee (map_id, heartbeat) VALUES (p_map_id, now());
}
return NOT busy;
$doom$;

CREATE OR REPLACE FUNCTION doom_mp_referee_beat(p_map_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
UPDATE mp_referee SET heartbeat=now() WHERE map_id=p_map_id;
return 1;
$doom$;

CREATE OR REPLACE FUNCTION doom_mp_referee_release(p_map_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
DELETE FROM mp_referee WHERE map_id=p_map_id;
return 1;
$doom$;

-- Ask the next tic to spawn every slot, so the referee can run the join path
-- once before anyone arrives: its first execution compiles for seconds, and
-- that stall must not land on the first player's join.
CREATE OR REPLACE FUNCTION doom_mp_request_all(p_map_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
INSERT INTO mp_join_requests (map_id, slot)
SELECT mp.map_id, mp.slot FROM mp_players mp WHERE mp.map_id=p_map_id
ON CONFLICT DO NOTHING;
return 1;
$doom$;

-- ---------------------------------------------------------------------------
-- The match: vanilla's command line as a row. -timer minutes become tics
-- (0: the level never times out), -altdeath, -nomonsters, -respawn.
CREATE OR REPLACE FUNCTION doom_mp_configure(p_map_id integer, p_skill integer, p_timer_tics integer, p_altdeath boolean, p_monsters boolean, p_respawn_monsters boolean, p_intermission_tics integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
DELETE FROM mp_match;
-- Closed until doom_mp_open: the referee opens the first map and compiles
-- the tic in peace, and no client writes meanwhile.
INSERT INTO mp_match (id, map_id, skill, state, timer_tics, altdeath, monsters, respawn_monsters, intermission_tics, intermission_until)
VALUES (0, p_map_id, p_skill, 'intermission', p_timer_tics, p_altdeath, p_monsters, p_respawn_monsters, p_intermission_tics, now());
return 1;
$doom$;

CREATE OR REPLACE FUNCTION doom_mp_open() RETURNS integer
LANGUAGE cedarscript AS $doom$
UPDATE mp_match SET state = 'playing', intermission_until = NULL;
return 1;
$doom$;

-- G_ExitLevel's reasons, for a deathmatch: -timer ran out, or any player
-- used or crossed an exit line, stood on the E1M8 boss floor worn down to
-- it, or the map's boss died
CREATE OR REPLACE FUNCTION doom_mp_level_done(p_map_id integer) RETURNS boolean
LANGUAGE cedarscript AS $doom$
let mut playing = false;
SELECT (m.state = 'playing') AS x FROM mp_match m WHERE m.map_id = p_map_id { playing = x; }
let mut done = false;
if playing {
  SELECT (m.timer_tics > 0 AND COALESCE(MAX(ps.level_tics), 0) >= m.timer_tics) AS d
  FROM mp_match m
  LEFT JOIN mp_players mp ON mp.map_id = m.map_id
  LEFT JOIN player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id
  WHERE m.map_id = p_map_id
  GROUP BY m.timer_tics { done = d; }
}
if playing AND NOT done {
  SELECT EXISTS (
    SELECT 1 FROM line_special_events e
    JOIN mp_players mp ON mp.map_id = e.map_id AND mp.player_thing_id = e.player_thing_id
    JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
    JOIN line_special_defs d ON d.special = ld.special
    WHERE e.map_id = p_map_id AND e.trigger_type = 'cross' AND d.is_exit
    UNION ALL
    SELECT 1 FROM line_use_results ur
    JOIN mp_players mp ON mp.map_id = ur.map_id AND mp.player_thing_id = ur.player_thing_id
    JOIN game_tic_commands c ON c.map_id = ur.map_id AND c.player_thing_id = ur.player_thing_id
    JOIN line_special_defs d ON d.special = ur.special
    WHERE ur.map_id = p_map_id AND ur.eligible AND c.use_requested AND d.is_exit
    UNION ALL
    SELECT 1 FROM player_state ps
    JOIN mp_players mp ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id
    JOIN sectors s ON s.map_id = ps.map_id AND s.id = ps.sector_id
    JOIN sector_special_defs sd ON sd.special = s.special
    WHERE ps.map_id = p_map_id AND mp.role_name IS NOT NULL
      AND ps.health <= sd.exit_at_health
    UNION ALL
    SELECT 1 FROM (
      SELECT SUM(CASE WHEN h.alive THEN 1 ELSE 0 END) AS alive_bosses
      FROM boss_actions ba
      JOIN maps m ON m.name = ba.map_name AND m.map_id = p_map_id
      JOIN things t ON t.map_id = m.map_id AND t.type = ba.boss_type
      JOIN thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id
      WHERE ba.action = 'exit_level'
      GROUP BY ba.map_name) q
    WHERE q.alive_bosses = 0
  ) AS e { done = e; }
}
return done;
$doom$;

-- WI_Start for a deathmatch: the world stops (the referee stops ticking), the
-- frag table is up, and the next map follows after intermission_tics.
CREATE OR REPLACE FUNCTION doom_mp_intermission_begin() RETURNS integer
LANGUAGE cedarscript AS $doom$
UPDATE mp_match
SET state = 'intermission',
    intermission_until = now() + (intermission_tics::double precision / 35.0) * interval '1 second'
WHERE state = 'playing';
return 1;
$doom$;

CREATE OR REPLACE FUNCTION doom_mp_intermission_over() RETURNS boolean
LANGUAGE cedarscript AS $doom$
let mut over = false;
SELECT (m.state = 'intermission' AND m.intermission_until <= now()) AS x FROM mp_match m { over = x; }
return over;
$doom$;

-- The map after the current one in mp_rotation, wrapping to the first
CREATE OR REPLACE FUNCTION doom_mp_next_map() RETURNS integer
LANGUAGE cedarscript AS $doom$
let mut cur_name = ''; let mut next_id = -1;
SELECT ma.name AS n FROM mp_match m JOIN maps ma ON ma.map_id = m.map_id { cur_name = n; }
SELECT ma.map_id AS id
FROM mp_rotation r JOIN maps ma ON ma.name = r.map_name
WHERE r.position > COALESCE((SELECT r2.position FROM mp_rotation r2 WHERE r2.map_name = cur_name), -1)
ORDER BY r.position LIMIT 1 { next_id = id; }
if next_id < 0 {
  SELECT ma.map_id AS id FROM mp_rotation r JOIN maps ma ON ma.name = r.map_name
  ORDER BY r.position LIMIT 1 { next_id = id; }
}
if next_id < 0 { SELECT m.map_id AS id FROM mp_match m { next_id = id; } }
return next_id;
$doom$;

-- G_DoCompleted -> G_DoLoadLevel for the match: the next map is opened with
-- fresh slots, and everyone who held a slot holds the same one there, to be
-- respawned by the first tic (a join request, like a fresh claim). Frags
-- start at zero per map, as vanilla's frag table does. Returns the new map.
CREATE OR REPLACE FUNCTION doom_mp_rotate() RETURNS integer
LANGUAGE cedarscript AS $doom$
let nxt = doom_mp_next_map();
let mut skill = 3;
SELECT m.skill AS s FROM mp_match m { skill = s; }
INSERT INTO mp_holders (slot, role_name, display_name, claimed_at)
SELECT mp.slot, mp.role_name, mp.display_name, mp.claimed_at FROM mp_players mp WHERE mp.role_name IS NOT NULL
ON CONFLICT (slot) DO UPDATE SET role_name = EXCLUDED.role_name, display_name = EXCLUDED.display_name,
  claimed_at = EXCLUDED.claimed_at;
DELETE FROM mp_holders h
WHERE NOT EXISTS (SELECT 1 FROM mp_players mp WHERE mp.slot = h.slot AND mp.role_name IS NOT NULL);
doom_mp_start(nxt, skill);
-- The seat follows the player, and so does the time they have held it.
UPDATE mp_players mp
SET role_name = h.role_name, display_name = h.display_name, claimed_at = h.claimed_at,
    last_seen = now() + interval '15 seconds'
FROM mp_holders h
WHERE mp.map_id = nxt AND mp.slot = h.slot;
INSERT INTO mp_join_requests (map_id, slot)
SELECT nxt, h.slot FROM mp_holders h
WHERE EXISTS (SELECT 1 FROM mp_players mp WHERE mp.map_id = nxt AND mp.slot = h.slot)
ON CONFLICT DO NOTHING;
DELETE FROM mp_inputs;
UPDATE mp_match
SET map_id = nxt, state = 'playing', intermission_until = NULL, maps_played = maps_played + 1;
return nxt;
$doom$;

-- What the referee prints every few seconds: the match and the world in one
-- row. Owner-only; every column is a small aggregate over the current map.
CREATE OR REPLACE VIEW mp_stats AS
SELECT m.map_id, ma.name AS map_name, m.state, m.timer_tics, m.maps_played,
       (SELECT COALESCE(MAX(ps.level_tics), 0) FROM player_state ps JOIN mp_players mp
         ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id
         WHERE mp.map_id = m.map_id) AS level_tics,
       (SELECT count(*) FROM thing_health h JOIN things t ON t.map_id = h.map_id AND t.id = h.thing_id
         JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
         WHERE h.map_id = m.map_id AND h.alive) AS monsters_alive,
       (SELECT count(*) FROM thing_health h JOIN things t ON t.map_id = h.map_id AND t.id = h.thing_id
         JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
         WHERE h.map_id = m.map_id) AS monsters_total,
       (SELECT count(*) FROM monster_ai ai JOIN thing_health h ON h.map_id = ai.map_id AND h.thing_id = ai.thing_id
         WHERE ai.map_id = m.map_id AND h.alive AND ai.state <> 'stand') AS monsters_awake,
       (SELECT count(*) FROM monster_projectiles p WHERE p.map_id = m.map_id) AS projectiles,
       (SELECT count(*) FROM world_effects e WHERE e.map_id = m.map_id) AS effects,
       (SELECT count(*) FROM picked_up_items pu JOIN things t ON t.map_id = pu.map_id AND t.id = pu.thing_id
         JOIN pickup_defs d ON d.thing_type = t.type WHERE pu.map_id = m.map_id) AS items_out,
       (SELECT count(*) FROM item_respawns r WHERE r.map_id = m.map_id) AS items_queued,
       (SELECT count(*) FROM sector_movers sm WHERE sm.map_id = m.map_id) AS movers,
       (SELECT count(*) FROM mp_inputs i) AS input_backlog,
       (SELECT count(*) FROM sound_events e WHERE e.map_id = m.map_id) AS sound_rows,
       (SELECT count(*) FROM pg_stat_activity a WHERE a.state IS NOT NULL) AS sessions,
       (SELECT count(*) FROM mp_waiting w WHERE EXTRACT(EPOCH FROM (now() - w.last_seen)) <= 5) AS waiting
FROM mp_match m JOIN maps ma ON ma.map_id = m.map_id;
