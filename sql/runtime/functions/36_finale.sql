CREATE OR REPLACE FUNCTION doom_finale_begin(p_episode integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
-- F_StartFinale. Returns 1 when this episode has a finale to show and 0 when
-- it does not, which is the caller's cue to go straight back to the title
-- screen rather than sit on an empty page.
let mut found = 0;
SELECT COUNT(*) AS n FROM finale_defs WHERE episode = p_episode::int
{ found = n; }
if found <> 0 {
  UPDATE screen_state
  SET screen='finale', finale_episode=p_episode::int,
      finale_count=0, finale_stage=0, cursor_index=0
  WHERE id=0;
}
return found;
$doom$;

CREATE OR REPLACE FUNCTION doom_finale_tic() RETURNS text
LANGUAGE cedarscript AS $doom$
-- One 35 Hz step of F_Ticker. The page types out at TEXTSPEED (3 tics a
-- character) and then sits for TEXTWAIT (250 tics) before the episode's
-- ending picture replaces it.
--
-- Returns 'text' while the page is up, 'picture' once the ending art is, and
-- 'done' if something else has taken the screen.
let mut result = 'text';

UPDATE screen_state s
SET finale_count = CASE WHEN d.advance THEN 0 ELSE s.finale_count + 1 END,
    finale_stage = CASE WHEN d.advance THEN 1 ELSE s.finale_stage END
FROM (
  SELECT s2.id,
         (s2.finale_stage = 0
          AND s2.finale_count + 1 > length(f.story_text) * 3 + 250) AS advance
  FROM screen_state s2
  JOIN finale_defs f ON f.episode = s2.finale_episode
  WHERE s2.id = 0 AND s2.screen = 'finale'
) d
WHERE s.id = d.id;

SELECT CASE WHEN screen <> 'finale' THEN 'done'
            WHEN finale_stage = 0 THEN 'text'
            ELSE 'picture' END AS r
FROM screen_state WHERE id=0
{ result = r; }
return result;
$doom$;

CREATE OR REPLACE FUNCTION doom_finale_advance() RETURNS text
LANGUAGE cedarscript AS $doom$
-- A keypress during the finale.
let mut result = 'text';
let mut stage = 0;
let mut count = 0;
let mut typed = 0;
SELECT s.finale_stage AS st, s.finale_count AS c,
       COALESCE(length(f.story_text), 0) * 3 + 10 AS t
FROM screen_state s
LEFT JOIN finale_defs f ON f.episode = s.finale_episode
WHERE s.id = 0
{ stage = st; count = c; typed = t; }

if stage <> 0 {
  UPDATE screen_state
  SET screen='title', finale_stage=0, finale_count=0, finale_episode=NULL,
      cursor_index=0
  WHERE id=0;
  result = 'done';
}
if stage = 0 AND count < typed {
  -- Still typing: put the whole page up at once, leaving the wait to run.
  UPDATE screen_state SET finale_count=typed WHERE id=0;
  result = 'text';
}
if stage = 0 AND count >= typed {
  UPDATE screen_state SET finale_stage=1, finale_count=0 WHERE id=0;
  result = 'picture';
}
return result;
$doom$;
