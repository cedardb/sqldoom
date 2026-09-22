-- Game flow

-- ---------------------------------------------------------------------------
-- G_RecordDemo: start recording under a name, replacing a demo of that name.
CREATE OR REPLACE FUNCTION doom_demo_begin(p_name text, p_map_id integer, p_player_thing_id integer, p_skill integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
let mut did = 0;
SELECT COALESCE((SELECT d.demo_id FROM demos d WHERE d.name=p_name),
                (SELECT COALESCE(MAX(x.demo_id),0)+1 FROM demos x)) AS i { did = i; }
DELETE FROM demo_tics WHERE demo_id=did;
INSERT INTO demos (demo_id,name,map_id,player_thing_id,skill,tic_count)
VALUES (did,p_name,p_map_id,p_player_thing_id,p_skill,0)
ON CONFLICT (demo_id) DO UPDATE
SET name=EXCLUDED.name, map_id=EXCLUDED.map_id,
    player_thing_id=EXCLUDED.player_thing_id, skill=EXCLUDED.skill,
    tic_count=0, recorded_at=NOW();
UPDATE screen_state SET demo_recording=did, demo_playing=NULL, demo_tic=0 WHERE id=0;
return did;
$doom$;

-- G_DeferedPlayDemo: play the named demo from its first tic. -1 if unknown.
CREATE OR REPLACE FUNCTION doom_demo_play(p_name text) RETURNS integer
LANGUAGE cedarscript AS $doom$
let mut did = -1;
SELECT d.demo_id AS i FROM demos d WHERE d.name=p_name { did = i; }
if did >= 0 {
  UPDATE screen_state SET demo_playing=did, demo_recording=NULL, demo_tic=0 WHERE id=0;
}
return did;
$doom$;

CREATE OR REPLACE FUNCTION doom_demo_stop()
LANGUAGE cedarscript AS $doom$
UPDATE screen_state SET demo_playing=NULL, demo_recording=NULL, demo_tic=0 WHERE id=0;
$doom$;

-- ---------------------------------------------------------------------------
-- D_DoAdvanceDemo. Vanilla alternates a page and a demo -- title, demo1,
-- credit, demo2, credit, demo3, demo4 -- holding the title for 170 tics and
-- the other pages for 200, and wraps. Here the pages alternate the same way
-- and the demos are whatever is seeded, so a build with one demo still cycles
-- title, demo, credit, demo rather than stalling.
CREATE OR REPLACE FUNCTION doom_attract_start()
LANGUAGE cedarscript AS $doom$
-- A client that died mid-demo leaves demo_playing set; a fresh start owns it.
UPDATE screen_state
SET attract_step=0, attract_pagetic=170, screen='title', cursor_index=0,
    demo_playing=NULL, demo_recording=NULL, demo_tic=0
WHERE id=0;
$doom$;

-- G_Responder: a key during the attract loop ends it. A demo that was playing
-- stops where it is and the title comes back.
CREATE OR REPLACE FUNCTION doom_attract_stop()
LANGUAGE cedarscript AS $doom$
UPDATE screen_state
SET attract_step=-1,
    screen=CASE WHEN demo_playing IS NOT NULL THEN 'title'::screen_kind ELSE screen END,
    demo_playing=NULL, demo_tic=0
WHERE id=0;
$doom$;

-- One 35 Hz step of the loop while a page is up. Returns 'none', 'page' (the
-- screen changed) or 'demo:<id>' (start that demo on its own map and skill).
CREATE OR REPLACE FUNCTION doom_attract_tic() RETURNS text
LANGUAGE cedarscript AS $doom$
let mut step = -1;
let mut pagetic = 0::real;
let mut playing = NULL::int;
SELECT attract_step, attract_pagetic, demo_playing FROM screen_state WHERE id=0
{ step = attract_step; pagetic = attract_pagetic; playing = demo_playing; }
if step < 0 OR playing IS NOT NULL { return 'none'; }
if pagetic > 1 {
  UPDATE screen_state SET attract_pagetic = attract_pagetic - 1 WHERE id=0;
  return 'none';
}
step = step + 1;
let mut n = 0;
SELECT count(*)::int AS c FROM demos { n = c; }
if n = 0 {
  UPDATE screen_state SET attract_step=step, attract_pagetic=170, screen='title', cursor_index=0 WHERE id=0;
  return 'page';
}
let slot = step % (2*n);
if slot % 2 = 0 {
  UPDATE screen_state
  SET attract_step=step,
      attract_pagetic=CASE WHEN slot=0 THEN 170 ELSE 200 END,
      screen=CASE WHEN slot=0 THEN 'title' ELSE 'help2' END, cursor_index=0
  WHERE id=0;
  return 'page';
}
let mut did = -1;
SELECT q.demo_id AS i
FROM (SELECT d.demo_id, ROW_NUMBER() OVER (ORDER BY d.demo_id) AS rn FROM demos d) q
WHERE q.rn = slot/2 + 1 { did = i; }
UPDATE screen_state
SET attract_step=step, attract_pagetic=0, demo_playing=did, demo_recording=NULL,
    demo_tic=0, screen='game'
WHERE id=0;
return 'demo:' || did::text;
$doom$;

-- ---------------------------------------------------------------------------
-- G_DoCompleted: freeze the level's totals, compute the tally and -- following
-- Doom's routing -- which level comes next. Returns its map_id, or -1 when
-- the episode ends here or that map is not loaded.
CREATE OR REPLACE FUNCTION doom_level_exit(p_map_id integer, p_player_thing_id integer, p_secret_exit boolean) RETURNS integer
LANGUAGE cedarscript AS $doom$
doom_finish_level(p_map_id,p_player_thing_id,p_secret_exit);
return doom_intermission_begin(p_map_id,p_player_thing_id,p_secret_exit);
$doom$;

-- G_WorldDone, once the tally has been dismissed: 'level:<map_id>' to enter
-- next, or 'finale' when the episode is over and has its text to show. An
-- episode with no finale seeded wraps to the first map so a demo keeps going.
CREATE OR REPLACE FUNCTION doom_after_intermission(p_map_id integer) RETURNS text
LANGUAGE cedarscript AS $doom$
let mut nxt = -1;
let mut ep = 1;
SELECT COALESCE(s.next_map_id,-1) AS n, substring(m.name FROM 2 FOR 1)::int AS e
FROM screen_state s, maps m WHERE s.id=0 AND m.map_id=p_map_id { nxt = n; ep = e; }
if nxt >= 0 { return 'level:' || nxt::text; }
let found = doom_finale_begin(ep);
if found <> 0 { return 'finale'; }
let mut first = 1;
SELECT MIN(map_id)::int AS f FROM maps { first = f; }
return 'level:' || first::text;
$doom$;

-- G_DoLoadLevel: the world reset, the player on their start, the level's
-- secret count recorded, and -- crossing from a finished level -- the state
-- the player actually ended it with put back over Doom's reborn loadout.
CREATE OR REPLACE FUNCTION doom_enter_level(p_map_id integer, p_player_thing_id integer, p_skill integer, p_from_map_id integer, p_from_player_thing_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
doom_reset_stage(p_map_id,p_skill);
doom_spawn_player(p_map_id,p_player_thing_id);
doom_cs_secret(p_map_id,p_player_thing_id);
if p_from_map_id IS NOT NULL {
  doom_carry_player(p_from_map_id,p_from_player_thing_id,p_map_id,p_player_thing_id);
}
UPDATE screen_state SET cheat_buffer='' WHERE id=0;
return 1;
$doom$;
