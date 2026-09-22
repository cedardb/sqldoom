-- One 35 Hz gameplay tic, for one to four players.

-- P_UseLines, when the plan says a use press is pending.
CREATE OR REPLACE FUNCTION doom_tic_use(p_map_id integer, p integer, p_plan bigint) RETURNS boolean
LANGUAGE cedarscript AS $doom$
let mut queued = false;
if (p_plan & 1) <> 0 { queued = doom_cs_use(p_map_id,p); }
return queued;
$doom$;

-- Movement: 1 = full move ran, 2 = turn only, 0 = nothing.
CREATE OR REPLACE FUNCTION doom_tic_move(p_map_id integer, p integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
let mode = doom_cs_movement_mode(p_map_id,p);
let mut did = 0;
if mode = 'full' { doom_cs_move(p_map_id,p); did = 1; }
if mode = 'turn' { doom_cs_turn(p_map_id,p); did = 2; }
return did;
$doom$;

-- Secret sectors, automap discovery, line crossings and pickups ride the
-- movement gate (plan bit 8): they only have anything to say when the player
-- has changed position. Returns the re-planned bits.
CREATE OR REPLACE FUNCTION doom_tic_secrets(p_map_id integer, p integer, p_plan bigint) RETURNS bigint
LANGUAGE cedarscript AS $doom$
let mut out = p_plan;
if (p_plan & 8) <> 0 {
  doom_cs_secret(p_map_id,p);
  doom_cs_discover(p_map_id,p);
  doom_cs_cross(p_map_id,p);
  doom_cs_pickups(p_map_id,p);
  out = doom_cs_plan(p_map_id,p);
}
return out;
$doom$;

-- Weapon state machine and, when it fired a hitscan weapon, the shot.
-- Returns the re-planned bits (bit 32 stays set once the shot has run).
CREATE OR REPLACE FUNCTION doom_tic_weapon(p_map_id integer, p integer, p_plan bigint) RETURNS bigint
LANGUAGE cedarscript AS $doom$
let mut out = p_plan;
if (p_plan & 16) <> 0 {
  let shot_serial = doom_cs_weapon(p_map_id,p);
  out = doom_cs_plan(p_map_id,p);
  if (out & 32) <> 0 {
    let impacts = doom_cs_hitscan_fire(p_map_id,p);
    if impacts >= 0 { doom_cs_hitscan_apply(p_map_id,p,shot_serial); }
  }
}
return out;
$doom$;

-- Deathmatch, per player: the PLAY frame the other clients draw this player
-- with, and P_DeathThink's respawn -- a second on the floor, then any fire or
-- use press.
CREATE OR REPLACE FUNCTION doom_tic_dm_player(p_map_id integer, p integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
doom_cs_player_pose(p_map_id,p);
let mut rs = false;
SELECT (NOT ps.alive AND ps.death_tics > 35 AND (g.attack_held OR g.use_requested)) AS r
FROM player_state ps
JOIN game_tic_commands g ON g.map_id=ps.map_id AND g.player_thing_id=ps.player_thing_id
WHERE ps.map_id=p_map_id AND ps.player_thing_id=p { rs = r; }
if rs { doom_mp_respawn(p_map_id,p); }
return 1;
$doom$;

CREATE OR REPLACE FUNCTION doom_run_tic_core(p_map_id integer, p_skill integer, p1 integer, p2 integer, p3 integer, p4 integer) RETURNS boolean
LANGUAGE cedarscript AS $doom$
-- Stage trace. Bits match dock.TIC_STAGES; see tic_trace in schema.sql.
let mut fired = 1::bigint;
let deathmatch = p2 IS NOT NULL;
let has3 = p3 IS NOT NULL;
let has4 = p4 IS NOT NULL;
doom_cs_clock(p_map_id,p1);
if deathmatch { doom_cs_clock(p_map_id,p2); }
if has3 { doom_cs_clock(p_map_id,p3); }
if has4 { doom_cs_clock(p_map_id,p4); }
fired = fired | 2::bigint;
let mut plan1 = doom_cs_plan(p_map_id,p1);
let mut plan2 = 0::bigint;
let mut plan3 = 0::bigint;
let mut plan4 = 0::bigint;
if deathmatch { plan2 = doom_cs_plan(p_map_id,p2); }
if has3 { plan3 = doom_cs_plan(p_map_id,p3); }
if has4 { plan4 = doom_cs_plan(p_map_id,p4); }
fired = fired | 4::bigint;
let mut plans = plan1 | plan2 | plan3 | plan4;
let mut sound_due = (plans & 128) <> 0;
let mut use_queued = doom_tic_use(p_map_id,p1,plan1);
if deathmatch { let u2 = doom_tic_use(p_map_id,p2,plan2); use_queued = use_queued OR u2; }
if has3 { let u3 = doom_tic_use(p_map_id,p3,plan3); use_queued = use_queued OR u3; }
if has4 { let u4 = doom_tic_use(p_map_id,p4,plan4); use_queued = use_queued OR u4; }
if (plans & 1) <> 0 { fired = fired | 8::bigint; }
let mut active = 0::bigint;
if (plans & 2) <> 0 OR use_queued {
  active = doom_cs_activate_specials(p_map_id);
  fired = fired | 16::bigint;
}
if (plans & 4) <> 0 OR active <> 0 {
  doom_cs_doors(p_map_id,p1);
  fired = fired | 32::bigint;
}
-- The plan once carried a scroller bit here. Special-48 wall scrolling is a
-- function of level_tics that the renderer applies per frame, so there was
-- nothing to step, and the bit is gone rather than left as a hole.
let did1 = doom_tic_move(p_map_id,p1);
if did1 = 1 { fired = fired | 128::bigint; }
if did1 = 2 { fired = fired | 256::bigint; }
if deathmatch { let d2 = doom_tic_move(p_map_id,p2); }
if has3 { let d3 = doom_tic_move(p_map_id,p3); }
if has4 { let d4 = doom_tic_move(p_map_id,p4); }
-- After the movement stage, so nothing writes the standing eye height back
-- over the sinking one. A no-op while the player is alive.
doom_cs_death(p_map_id,p1);
if deathmatch { doom_cs_death(p_map_id,p2); }
if has3 { doom_cs_death(p_map_id,p3); }
if has4 { doom_cs_death(p_map_id,p4); }
plan1 = doom_cs_plan(p_map_id,p1);
if deathmatch { plan2 = doom_cs_plan(p_map_id,p2); }
if has3 { plan3 = doom_cs_plan(p_map_id,p3); }
if has4 { plan4 = doom_cs_plan(p_map_id,p4); }
plans = plan1 | plan2 | plan3 | plan4;
sound_due = sound_due OR (plans & 128) <> 0;
if (plans & 8) <> 0 { fired = fired | 512::bigint | 1024::bigint | 2048::bigint; }
plan1 = doom_tic_secrets(p_map_id,p1,plan1);
if deathmatch { plan2 = doom_tic_secrets(p_map_id,p2,plan2); }
if has3 { plan3 = doom_tic_secrets(p_map_id,p3,plan3); }
if has4 { plan4 = doom_tic_secrets(p_map_id,p4,plan4); }
plans = plan1 | plan2 | plan3 | plan4;
sound_due = sound_due OR (plans & 128) <> 0;
if (plans & 16) <> 0 { fired = fired | 4096::bigint; }
plan1 = doom_tic_weapon(p_map_id,p1,plan1);
if deathmatch { plan2 = doom_tic_weapon(p_map_id,p2,plan2); }
if has3 { plan3 = doom_tic_weapon(p_map_id,p3,plan3); }
if has4 { plan4 = doom_tic_weapon(p_map_id,p4,plan4); }
plans = plan1 | plan2 | plan3 | plan4;
sound_due = sound_due OR (plans & 128) <> 0;
if (plans & 32) <> 0 { fired = fired | 8192::bigint | 16384::bigint; }
-- World stages once. The projectile stage spawns every player's missiles and
-- tests every player as a target; the sound stage runs per player because its
-- player cues are keyed by player, while its world cues dedupe on their keys.
-- The player the world stages see: in a deathmatch a different live, held
-- slot every tic, so monsters notice everyone (doom_cs_monsters keeps the
-- target a monster picked; this only decides who is offered).
let mut pm = p1;
if deathmatch {
  SELECT q.player_thing_id AS x
  FROM (SELECT mp.player_thing_id, ps.level_tics,
               ROW_NUMBER() OVER (ORDER BY mp.slot) AS rn, COUNT(*) OVER () AS n
        FROM mp_players mp
        JOIN player_state ps ON ps.map_id=mp.map_id AND ps.player_thing_id=mp.player_thing_id
        WHERE mp.map_id=p_map_id AND mp.role_name IS NOT NULL AND ps.alive) q
  WHERE q.rn = (q.level_tics % q.n) + 1 { pm = x; }
}
if (plans & 64) <> 0 {
  doom_cs_projectiles(p_map_id,pm);
  fired = fired | 32768::bigint;
  plan1 = doom_cs_plan(p_map_id,p1);
  if deathmatch { plan2 = doom_cs_plan(p_map_id,p2); }
  if has3 { plan3 = doom_cs_plan(p_map_id,p3); }
  if has4 { plan4 = doom_cs_plan(p_map_id,p4); }
  sound_due = sound_due OR ((plan1 | plan2 | plan3 | plan4) & 128) <> 0;
}
if sound_due {
  doom_cs_sound(p_map_id,p1);
  if deathmatch { doom_cs_sound(p_map_id,p2); }
  if has3 { doom_cs_sound(p_map_id,p3); }
  if has4 { doom_cs_sound(p_map_id,p4); }
  fired = fired | 65536::bigint;
}
doom_cs_monsters(p_map_id,pm);
fired = fired | 131072::bigint;
if deathmatch { doom_cs_item_respawn(p_map_id,p1); }
-- Animated sector lighting and damaging floors. Unconditional like the
-- monsters: it writes only the sectors whose value actually changed, so an
-- idle tic costs a comparison per animated sector and nothing else.
doom_cs_sector_fx(p_map_id,p1);
if deathmatch { doom_cs_sector_fx(p_map_id,p2); }
if has3 { doom_cs_sector_fx(p_map_id,p3); }
if has4 { doom_cs_sector_fx(p_map_id,p4); }
fired = fired | 262144::bigint;
-- P_XYMovement for Things, after the monsters have handed out their damage so
-- a shove given this tic is carried this tic. Reads nothing when nothing is
-- moving, which is almost always.
doom_cs_thing_physics(p_map_id);
-- A_BossDeath, after the monsters have taken their damage for this tic so a
-- boss that died in it counts immediately. Cheap on every ordinary map: the
-- aggregate it runs has no group to work on unless the map is in
-- boss_actions.
doom_cs_boss(p_map_id);
fired = fired | 524288::bigint;

if deathmatch {
  -- Scoreboard once, then each player's pose and respawn.
  doom_mp_frags(p_map_id);
  doom_tic_dm_player(p_map_id,p1);
  doom_tic_dm_player(p_map_id,p2);
  if has3 { doom_tic_dm_player(p_map_id,p3); }
  if has4 { doom_tic_dm_player(p_map_id,p4); }
}

-- Most consecutive tics run exactly the same set of stages, and the client
-- re-reads this row every tic regardless, so skipping the unchanged writes
-- costs it nothing and saves a row version per tic.
INSERT INTO tic_trace (map_id,player_thing_id,stages)
VALUES (p_map_id::int,p1::int,fired)
ON CONFLICT (map_id,player_thing_id) DO UPDATE SET stages=EXCLUDED.stages
WHERE tic_trace.stages <> EXCLUDED.stages;

return sound_due;
$doom$;

-- Single player: the client's command straight in, then the shared tic.
CREATE OR REPLACE FUNCTION doom_run_game_tic(p_map_id integer, p_player_thing_id integer, p_skill integer, p_move_fwd real, p_move_strafe real, p_running boolean, p_turn_degrees real, p_attack_held boolean, p_weapon_switch_to integer, p_use_requested boolean) RETURNS boolean
LANGUAGE cedarscript AS $doom$
doom_cs_begin(
  p_map_id,p_player_thing_id,p_skill,p_move_fwd,p_move_strafe,
  p_running,p_turn_degrees,p_attack_held,p_weapon_switch_to,p_use_requested);
-- G_ReadDemoTiccmd / G_WriteDemoTiccmd: while a demo plays, its recorded
-- command replaces the client's; while one records, the command is appended.
-- Past the last recorded tic the demo ends, and if the attract loop started
-- it the title comes back for the loop's next page.
let mut playing = NULL::int;
let mut recording = NULL::int;
let mut dtic = 0;
SELECT demo_playing, demo_recording, demo_tic FROM screen_state WHERE id=0
{ playing = demo_playing; recording = demo_recording; dtic = demo_tic; }
if playing IS NOT NULL {
  let mut have = false;
  SELECT EXISTS (SELECT 1 FROM demo_tics d WHERE d.demo_id=playing AND d.tic=dtic) AS e
  { have = e; }
  if have {
    UPDATE game_tic_commands g
    SET move_fwd=d.move_fwd, move_strafe=d.move_strafe, running=d.running,
        turn_degrees=d.turn_degrees, attack_held=d.attack_held,
        weapon_switch_to=d.weapon_switch_to, use_requested=d.use_requested
    FROM demo_tics d
    WHERE d.demo_id=playing AND d.tic=dtic
      AND g.map_id=p_map_id AND g.player_thing_id=p_player_thing_id;
    UPDATE screen_state SET demo_tic=demo_tic+1 WHERE id=0;
  }
  if NOT have {
    UPDATE screen_state
    SET demo_playing=NULL, demo_tic=0,
        screen=CASE WHEN attract_step>=0 THEN 'title'::screen_kind ELSE screen END,
        attract_pagetic=0
    WHERE id=0;
  }
}
if recording IS NOT NULL {
  INSERT INTO demo_tics
    (demo_id,tic,move_fwd,move_strafe,running,turn_degrees,attack_held,
     weapon_switch_to,use_requested)
  SELECT recording,dtic,g.move_fwd,g.move_strafe,g.running,g.turn_degrees,
         g.attack_held,g.weapon_switch_to,g.use_requested
  FROM game_tic_commands g
  WHERE g.map_id=p_map_id AND g.player_thing_id=p_player_thing_id
  ON CONFLICT (demo_id,tic) DO UPDATE SET
    move_fwd=EXCLUDED.move_fwd, move_strafe=EXCLUDED.move_strafe,
    running=EXCLUDED.running, turn_degrees=EXCLUDED.turn_degrees,
    attack_held=EXCLUDED.attack_held,
    weapon_switch_to=EXCLUDED.weapon_switch_to,
    use_requested=EXCLUDED.use_requested;
  UPDATE demos SET tic_count=GREATEST(tic_count,dtic+1) WHERE demo_id=recording;
  UPDATE screen_state SET demo_tic=demo_tic+1 WHERE id=0;
}
let nobody = NULL::int;
return doom_run_tic_core(p_map_id,p_skill,p_player_thing_id,nobody,nobody,nobody);
$doom$;

-- ---------------------------------------------------------------------------
-- One deathmatch tic: fold each client's input rows into a command, record
-- them, spawn the players whose slots were just claimed, then run the shared
-- tic (doom_run_tic_core) for every occupied slot (p2..p4 NULL when a map
-- has fewer starts).

-- The input rows one client appended since the last tic, folded into its
-- command: the latest movement values, the summed turn, any press.
CREATE OR REPLACE FUNCTION doom_mp_begin_player(p_map_id integer, p_skill integer, p integer, p_upto bigint) RETURNS integer
LANGUAGE cedarscript AS $doom$
let mut mf = 0::real; let mut ms = 0::real; let mut mr = false; let mut mt = 0::real;
let mut ma = false; let mut mw = NULL::int; let mut mu = false;
SELECT COALESCE(ARG_MAX(move_fwd, seq), 0)::real AS f,
       COALESCE(ARG_MAX(move_strafe, seq), 0)::real AS s,
       COALESCE(ARG_MAX(running, seq), FALSE) AS r,
       COALESCE(SUM(turn_degrees), 0)::real AS t,
       COALESCE(BOOL_OR(attack_held), FALSE) AS a,
       MAX(weapon_switch_to)::int AS w,
       COALESCE(BOOL_OR(use_requested), FALSE) AS u
FROM mp_inputs WHERE map_id=p_map_id AND player_thing_id=p AND seq <= p_upto
{ mf = f; ms = s; mr = r; mt = t; ma = a; mw = w; mu = u; }
doom_cs_begin(p_map_id,p,p_skill,mf,ms,mr,mt,ma,mw,mu);
return 1;
$doom$;

-- A slot claimed since the last tic (api_join): a fresh body and a clean
-- score. Only this player's request is deleted: a join for another slot
-- landing at this very moment must not be touched, or one of the two fails
-- to serialize.
CREATE OR REPLACE FUNCTION doom_mp_spawn_if_requested(p_map_id integer, p integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
let mut spawn = false;
SELECT EXISTS(SELECT 1 FROM mp_join_requests r JOIN mp_players mp
              ON mp.map_id=r.map_id AND mp.slot=r.slot
              WHERE mp.map_id=p_map_id AND mp.player_thing_id=p) AS e { spawn = e; }
if spawn {
  UPDATE player_state SET frags=0 WHERE map_id=p_map_id AND player_thing_id=p;
  doom_mp_respawn(p_map_id,p);
  DELETE FROM mp_join_requests WHERE map_id=p_map_id
    AND slot IN (SELECT mp.slot FROM mp_players mp
                 WHERE mp.map_id=p_map_id AND mp.player_thing_id=p);
}
return 1;
$doom$;

CREATE OR REPLACE FUNCTION doom_run_mp_tic(p_map_id integer, p_skill integer, p1 integer, p2 integer, p3 integer, p4 integer) RETURNS boolean
LANGUAGE cedarscript AS $doom$
-- Consume every input row that exists now; rows a client appends during the
-- tic are next tic's.
let mut upto = 0::bigint;
SELECT COALESCE(MAX(seq),0)::bigint AS m FROM mp_inputs WHERE map_id=p_map_id { upto = m; }
doom_mp_spawn_if_requested(p_map_id,p1);
if p2 IS NOT NULL { doom_mp_spawn_if_requested(p_map_id,p2); }
if p3 IS NOT NULL { doom_mp_spawn_if_requested(p_map_id,p3); }
if p4 IS NOT NULL { doom_mp_spawn_if_requested(p_map_id,p4); }
doom_mp_begin_player(p_map_id,p_skill,p1,upto);
if p2 IS NOT NULL { doom_mp_begin_player(p_map_id,p_skill,p2,upto); }
if p3 IS NOT NULL { doom_mp_begin_player(p_map_id,p_skill,p3,upto); }
if p4 IS NOT NULL { doom_mp_begin_player(p_map_id,p_skill,p4,upto); }
DELETE FROM mp_inputs WHERE map_id=p_map_id AND seq <= upto;
doom_run_tic_core(p_map_id,p_skill,p1,p2,p3,p4);
-- TRUE when this tic ended the level: the referee then runs the intermission
-- and moves the match on (doom_mp_rotate).
return doom_mp_level_done(p_map_id);
$doom$;
