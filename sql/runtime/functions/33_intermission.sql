CREATE OR REPLACE FUNCTION doom_intermission_begin(p_map_id integer, p_player_thing_id integer, p_secret_exit boolean) RETURNS integer
LANGUAGE cedarscript AS $doom$
-- Enter the intermission for a finished level and work out what comes next.
let mut next_id = -1;

WITH cur AS (
  SELECT m.map_id, m.name,
         substring(m.name FROM 2 FOR 1)::int AS ep,
         substring(m.name FROM 4 FOR 1)::int AS lv
  FROM maps m WHERE m.map_id = p_map_id::int
),
route AS (
  SELECT c.*,
    CASE
      WHEN p_secret_exit::boolean THEN 9
      WHEN c.lv = 9 THEN
        CASE c.ep WHEN 1 THEN 4 WHEN 2 THEN 6 WHEN 3 THEN 7 ELSE 3 END
      WHEN c.lv = 8 THEN NULL
      ELSE c.lv + 1
    END AS next_lv
  FROM cur c
),
resolved AS (
  SELECT r.*,
         (SELECT n.map_id FROM maps n
           WHERE n.name = 'E' || r.ep::text || 'M' || r.next_lv::text) AS next_id
  FROM route r
),
stats AS (
  SELECT ls.*,
         -- Doom divides by the level totals; a level holding none of a thing
         -- shows zero rather than dividing by zero.
         CASE WHEN ls.total_kills   > 0
              THEN LEAST(100, ls.kills   * 100 / ls.total_kills)   ELSE 0 END AS pk,
         CASE WHEN ls.total_items   > 0
              THEN LEAST(100, ls.items   * 100 / ls.total_items)   ELSE 0 END AS pi,
         CASE WHEN ls.total_secrets > 0
              THEN LEAST(100, ls.secrets * 100 / ls.total_secrets) ELSE 0 END AS ps
  FROM level_stats ls
  WHERE ls.map_id = p_map_id::int AND ls.player_thing_id = p_player_thing_id::int
)
UPDATE screen_state s
SET screen='intermission', cursor_index=0,
    inter_episode=r.ep, inter_level=r.lv,
    inter_next=COALESCE(r.next_lv, r.lv),
    next_map_id=r.next_id, secret_exit=p_secret_exit::boolean,
    tgt_kills=st.pk, tgt_items=st.pi, tgt_secrets=st.ps,
    tgt_time=(st.level_tics/35)::int,
    tgt_par=COALESCE((st.par_tics/35)::int, 0),
    kills_pct=0, items_pct=0, secrets_pct=0, time_secs=0, par_secs=0,
    sp_state=1, cnt_pause=35, accelerate=FALSE
FROM resolved r, stats st
WHERE s.id=0;

SELECT COALESCE(MIN(next_map_id), -1) AS n FROM screen_state WHERE id=0
{ next_id = n; }
return next_id;
$doom$;

CREATE OR REPLACE FUNCTION doom_intermission_accelerate() RETURNS integer
LANGUAGE cedarscript AS $doom$
-- A keypress during the tally. Doom's acceleratestage: it snaps the current
-- figure to its target, and once everything is shown it leaves the screen.
UPDATE screen_state SET accelerate=TRUE WHERE id=0;
return 0;
$doom$;

CREATE OR REPLACE FUNCTION doom_intermission_tic() RETURNS text
LANGUAGE cedarscript AS $doom$
-- One 35 Hz step of WI_updateStats
--   sp_state 2 kills, 4 items, 6 secrets  -- +2 percent a tic
--   sp_state 8 time and par               -- +3 seconds a tic
--   odd states                            -- a one-second pause
--   sp_state 10                           -- everything shown, waiting
--
-- Returns 'counting' while the tally runs, 'waiting' once it is all on
-- screen, and 'done' when a keypress has dismissed it.
let mut result = 'counting';
let mut pre_accel = false;
let mut pre_state = 0;
SELECT accelerate AS a, sp_state AS st FROM screen_state WHERE id=0
{ pre_accel = a; pre_state = st; }

UPDATE screen_state s
SET
  -- An accelerating keypress fills every figure in at once.
  kills_pct = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_kills
      WHEN s.sp_state = 2 THEN LEAST(s.tgt_kills, s.kills_pct + 2)
      ELSE s.kills_pct END,
  items_pct = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_items
      WHEN s.sp_state = 4 THEN LEAST(s.tgt_items, s.items_pct + 2)
      ELSE s.items_pct END,
  secrets_pct = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_secrets
      WHEN s.sp_state = 6 THEN LEAST(s.tgt_secrets, s.secrets_pct + 2)
      ELSE s.secrets_pct END,
  time_secs = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_time
      WHEN s.sp_state = 8 THEN LEAST(s.tgt_time, s.time_secs + 3)
      ELSE s.time_secs END,
  par_secs = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_par
      WHEN s.sp_state = 8 THEN LEAST(s.tgt_par, s.par_secs + 3)
      ELSE s.par_secs END,
  sp_state = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN 10
      -- A counting state ends when its figure reaches the target.
      WHEN s.sp_state = 2 AND s.kills_pct + 2 >= s.tgt_kills THEN 3
      WHEN s.sp_state = 4 AND s.items_pct + 2 >= s.tgt_items THEN 5
      WHEN s.sp_state = 6 AND s.secrets_pct + 2 >= s.tgt_secrets THEN 7
      WHEN s.sp_state = 8 AND s.time_secs + 3 >= s.tgt_time
                          AND s.par_secs + 3 >= s.tgt_par THEN 10
      -- A pause state ends when its second runs out.
      WHEN s.sp_state IN (1,3,5,7,9) AND s.cnt_pause <= 1 THEN s.sp_state + 1
      ELSE s.sp_state END,
  cnt_pause = CASE
      WHEN s.sp_state IN (1,3,5,7,9) AND s.cnt_pause > 1 THEN s.cnt_pause - 1
      WHEN s.sp_state IN (1,3,5,7,9) THEN 35
      ELSE s.cnt_pause END,
  accelerate = FALSE
WHERE s.id = 0;

SELECT CASE WHEN screen <> 'intermission' THEN 'done'
            WHEN sp_state >= 10 THEN 'waiting'
            ELSE 'counting' END AS r
FROM screen_state WHERE id=0
{ result = r; }
if pre_accel AND pre_state >= 10 {
  UPDATE screen_state SET screen='game', sp_state=0, cnt_pause=0 WHERE id=0;
  result = 'done';
}
return result;
$doom$;
