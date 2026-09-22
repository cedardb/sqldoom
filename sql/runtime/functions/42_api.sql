-- The player-facing API of the deathmatch server.
--
-- A player client connects as its own database role and holds no table
-- grants at all. Everything it may do is one of these SECURITY DEFINER
-- functions, and everything it may see is one of the api_* views installed by
-- cedarscript_runtime.install_api_views (which run with their owner's rights).

-- Join the match
CREATE OR REPLACE FUNCTION api_join() RETURNS integer
LANGUAGE cedarscript SECURITY DEFINER AS $doom$
let mut spectator = false;
SELECT EXISTS (SELECT 1 FROM api_spectator_roles s WHERE s.role_name = session_user::text) AS x { spectator = x; }
if spectator { return -1; }
let mut pid = -1;
SELECT mp.player_thing_id AS p FROM mp_players mp
WHERE mp.role_name = session_user::text { pid = p; }
if pid < 0 {
  -- The queue: a caller without a slot is a waiter from its first call, and
  -- stays one while it keeps calling (the page asks once a second). Waiters
  -- quiet for five seconds have left. First come, first served: a free slot
  -- goes to the earliest waiter only.
  INSERT INTO mp_waiting (role_name, since, last_seen) VALUES (session_user::text, now(), now())
  ON CONFLICT (role_name) DO UPDATE SET last_seen = now();
}
-- Between maps nothing is claimed or written to the slot table: the referee
-- is moving the slots to the next map and a concurrent write would only make
-- it retry. The client asks again in a second; api_match says what is going on.
let mut playing = false;
SELECT (m.state = 'playing') AS x FROM mp_match m { playing = x; }
if NOT playing { return -1; }
let mut claim = -1; let mut claim_map = 0; let mut claim_slot = 0;
let mut first = false;
SELECT NOT EXISTS (SELECT 1 FROM mp_waiting w, mp_waiting me
                   WHERE me.role_name = session_user::text AND w.since < me.since) AS x { first = x; }
if pid < 0 AND first {
  SELECT mp.map_id AS m, mp.slot AS s, mp.player_thing_id AS p FROM mp_players mp
  WHERE mp.role_name IS NULL ORDER BY mp.map_id, mp.slot LIMIT 1
  { claim_map = m; claim_slot = s; claim = p; }
}
if claim >= 0 {
  UPDATE mp_players SET role_name = session_user::text, claimed_at = now()
  WHERE map_id = claim_map AND slot = claim_slot AND role_name IS NULL;
  DELETE FROM mp_waiting WHERE role_name = session_user::text;
  INSERT INTO mp_join_requests (map_id, slot) VALUES (claim_map, claim_slot)
  ON CONFLICT DO NOTHING;
  pid = claim;
}
if pid >= 0 {
  UPDATE mp_players SET last_seen = now() WHERE role_name = session_user::text;
}
if claim >= 0 {
  -- A fresh claim gets a grace period before the reaper may take the slot
  -- back: the client compiles its frame statement next, which takes several
  -- seconds when several players join at once and would otherwise outlast
  -- IDLE_SECONDS. The heartbeats never shorten it (api_camera), so it is
  -- also how long a slot stays held after someone joins and leaves at once;
  -- 15 s covers the compile and keeps that wait short for the next in line.
  UPDATE mp_players SET last_seen = now() + interval '15 seconds'
  WHERE role_name = session_user::text;
}
return pid;
$doom$;

-- Which slot the caller holds (1 to 4), -1 for none. The frame views are per
-- slot: api_frame_slot<n> and api_frame_idx_slot<n>.
CREATE OR REPLACE FUNCTION api_slot() RETURNS integer
LANGUAGE cedarscript SECURITY DEFINER AS $doom$
let mut s = -1;
SELECT mp.slot AS n FROM mp_players mp
WHERE mp.role_name = session_user::text { s = n; }
return s;
$doom$;

-- One frame of input, appended for the caller's slot. Values are clamped to
-- what the keyboard can produce, so no client is faster than another.
CREATE OR REPLACE FUNCTION api_input(p_fwd real, p_strafe real, p_run boolean, p_turn real, p_fire boolean, p_weapon integer, p_use boolean) RETURNS integer
LANGUAGE cedarscript SECURITY DEFINER AS $doom$
let mut playing = false;
SELECT (m.state = 'playing') AS x FROM mp_match m { playing = x; }
if playing {
INSERT INTO mp_inputs
  (map_id,player_thing_id,move_fwd,move_strafe,running,turn_degrees,
   attack_held,weapon_switch_to,use_requested)
SELECT mp.map_id, mp.player_thing_id,
       LEAST(1.0, GREATEST(-1.0, COALESCE(p_fwd, 0)))::real,
       LEAST(1.0, GREATEST(-1.0, COALESCE(p_strafe, 0)))::real,
       COALESCE(p_run, FALSE),
       LEAST(180.0, GREATEST(-180.0, COALESCE(p_turn, 0)))::real,
       COALESCE(p_fire, FALSE),
       CASE WHEN p_weapon BETWEEN 1 AND 8 THEN p_weapon END,
       COALESCE(p_use, FALSE)
FROM mp_players mp WHERE mp.role_name = session_user::text;
}
return 1;
$doom$;


-- Number-key weapon selection and mouse-wheel cycling, over the caller's
-- own weapons (the same rules as sql/client/weapon_slot.sql and
-- weapon_cycle.sql). -1 when the slot holds nothing the caller owns.
CREATE OR REPLACE FUNCTION api_weapon_slot(p_slot integer) RETURNS integer
LANGUAGE cedarscript SECURITY DEFINER AS $doom$
let mut w = -1;
SELECT wd.weapon_id AS id
FROM mp_players mp
JOIN player_weapon_owned o ON o.map_id=mp.map_id AND o.player_thing_id=mp.player_thing_id
JOIN weapon_defs wd ON wd.weapon_id=o.weapon_id
JOIN player_weapons pw ON pw.map_id=o.map_id AND pw.player_thing_id=o.player_thing_id
WHERE mp.role_name = session_user::text AND wd.slot=p_slot
ORDER BY CASE
  WHEN p_slot=1 AND pw.current_weapon=8 AND wd.weapon_id=1 THEN 0
  WHEN p_slot=1 AND pw.current_weapon<>8 AND wd.weapon_id=8 THEN 0
  WHEN wd.weapon_id=pw.current_weapon THEN 2 ELSE 1 END,
  wd.weapon_id DESC
LIMIT 1 { w = id; }
return w;
$doom$;

CREATE OR REPLACE FUNCTION api_weapon_cycle(p_step integer) RETURNS integer
LANGUAGE cedarscript SECURITY DEFINER AS $doom$
let mut w = -1;
WITH me AS (
  SELECT mp.map_id, mp.player_thing_id FROM mp_players mp
  WHERE mp.role_name = session_user::text
),
owned AS (
  SELECT wd.weapon_id,
         ROW_NUMBER() OVER (ORDER BY wd.slot, wd.weapon_id) AS pos,
         COUNT(*) OVER () AS n
  FROM me JOIN player_weapon_owned o ON o.map_id=me.map_id AND o.player_thing_id=me.player_thing_id
  JOIN weapon_defs wd ON wd.weapon_id = o.weapon_id
),
here AS (
  SELECT o.pos, o.n
  FROM owned o JOIN me ON TRUE
  JOIN player_weapons pw ON pw.map_id = me.map_id AND pw.player_thing_id = me.player_thing_id
   AND pw.current_weapon = o.weapon_id
)
SELECT o.weapon_id AS id
FROM owned o CROSS JOIN here h
WHERE o.pos = ((h.pos - 1 + p_step + h.n) % h.n) + 1 { w = id; }
return w;
$doom$;

-- The name the scoreboard and the frag messages use for the caller: letters,
-- digits, space, - and _, at most 12, upper case like everything the HUD
-- font can draw. Empty clears it back to the role name.
CREATE OR REPLACE FUNCTION api_set_name(p_name text) RETURNS integer
LANGUAGE cedarscript SECURITY DEFINER AS $doom$
UPDATE mp_players
SET display_name = NULLIF(TRIM(UPPER(LEFT(REGEXP_REPLACE(COALESCE(p_name, ''), '[^A-Za-z0-9 _-]', '', 'g'), 12))), '')
WHERE role_name = session_user::text;
return 1;
$doom$;
