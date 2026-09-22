CREATE OR REPLACE FUNCTION doom_cs_sound(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let active_sound_odds = doom_const('ACTIVE_SOUND_ODDS');
let sound_trim_age = doom_const('SOUND_TRIM_AGE_TICS');
let sound_trim_interval = doom_const('SOUND_TRIM_INTERVAL_TICS');
-- Emit one tic's sound events
WITH
pickup AS (
  SELECT map_id,player_thing_id,COUNT(*)>0 AS changed
  FROM pickup_touches GROUP BY map_id,player_thing_id
),
weapon_grant AS (
  SELECT map_id,player_thing_id,COUNT(*)>0 AS granted
  FROM pickup_grants GROUP BY map_id,player_thing_id
),
input AS (
  SELECT g.map_id,g.player_thing_id,ps.level_tics AS level_tic,
         COALESCE(p.changed,FALSE) AS pickup_changed,
         COALESCE(gr.granted,FALSE) AS weapon_granted,g.use_requested
  FROM game_tic_commands g
  JOIN player_state ps ON ps.map_id=g.map_id
    AND ps.player_thing_id=g.player_thing_id
  LEFT JOIN pickup p ON p.map_id=g.map_id AND p.player_thing_id=g.player_thing_id
  LEFT JOIN weapon_grant gr ON gr.map_id=g.map_id
    AND gr.player_thing_id=g.player_thing_id
  WHERE g.map_id=p_map_id::int AND g.player_thing_id=p_player_thing_id::int
),
player_pos AS (
  SELECT i.*,t.x::real AS px,t.y::real AS py
  FROM input i JOIN things t ON t.map_id=i.map_id AND t.id=i.player_thing_id
),
sound_pick AS (
  SELECT d.thing_type, d.cue, d.variant, d.sound_name,
         COUNT(*) OVER (PARTITION BY d.thing_type, d.cue) AS n
  FROM thing_sound_defs d
),
events AS (
  SELECT p.map_id,'player-fire:'||p.player_thing_id::text||':'||pw.shot_serial::text AS event_key,
         p.level_tic,
         CASE pw.current_weapon
           WHEN 1 THEN 'DSPUNCH' WHEN 2 THEN 'DSPISTOL'
           WHEN 3 THEN 'DSSHOTGN' WHEN 4 THEN 'DSPISTOL'
           WHEN 5 THEN 'DSRLAUNC' WHEN 6 THEN 'DSPLASMA'
           WHEN 7 THEN 'DSBFG' WHEN 8 THEN NULL
         END AS sound_name,p.player_thing_id AS source_thing_id,
         p.px AS source_x,p.py AS source_y
  FROM player_pos p JOIN player_weapons pw
    ON pw.map_id=p.map_id AND pw.player_thing_id=p.player_thing_id
  WHERE pw.fired_this_tick

  UNION ALL
  SELECT p.map_id,'pickup:'||p.player_thing_id::text||':'||p.level_tic::text,p.level_tic,
         CASE WHEN p.weapon_granted THEN 'DSWPNUP' ELSE 'DSITEMUP' END,
         p.player_thing_id,p.px,p.py
  FROM player_pos p WHERE p.pickup_changed

  UNION ALL
  SELECT p.map_id,'use:'||p.player_thing_id::text||':'||p.level_tic::text,p.level_tic,
         CASE
           WHEN COALESCE(r.locked,FALSE) THEN 'DSOOF'
           WHEN COALESCE(r.eligible,FALSE) AND r.special IN
                (1,26,27,28,31,32,33,34,117,118) THEN 'DSDOROPN'
           WHEN COALESCE(r.eligible,FALSE) THEN 'DSSWTCHN'
           ELSE 'DSNOWAY'
         END,
         p.player_thing_id,p.px,p.py
  FROM player_pos p
  LEFT JOIN line_use_results r ON r.map_id=p.map_id
    AND r.player_thing_id=p.player_thing_id
  WHERE p.use_requested

  UNION ALL
  SELECT p.map_id,
         'monster-fire:'||ai.thing_id::text||':'||p.level_tic::text,
         p.level_tic,
         CASE
           WHEN d.attack_sound IS NOT NULL THEN d.attack_sound
           WHEN d.missile_type IS NOT NULL
                AND NOT (d.melee_mult IS NOT NULL
                         AND sqrt(power(t.x-p.px,2)+power(t.y-p.py,2))<=64.0)
             THEN 'DSFIRSHT'
           ELSE 'DSCLAW'
         END,
         ai.thing_id,t.x::real,t.y::real
  FROM player_pos p JOIN monster_ai ai ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type=t.type
  WHERE ai.fired_this_tick

  UNION ALL
  SELECT p.map_id,'impact:'||i.projectile_id::text,p.level_tic,
         CASE i.projectile_type WHEN 'rocket' THEN 'DSRXPLOD'
              ELSE 'DSFIRXPL' END,
         i.owner_thing_id,i.x::real,i.y::real
  FROM player_pos p JOIN projectile_impacts i ON i.map_id=p.map_id

  UNION ALL
  SELECT p.map_id,'mon-sight:'||ai.thing_id::text,p.level_tic,sp.sound_name,
         ai.thing_id,t.x::real,t.y::real
  FROM player_pos p
  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state <> 'stand'
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND h.alive
  JOIN sound_pick sp ON sp.thing_type=t.type AND sp.cue='sight'
   AND sp.variant = doom_prandom(ai.thing_id, 0, 60) % sp.n

  UNION ALL
  SELECT p.map_id,'mon-death:'||ai.thing_id::text,p.level_tic,sp.sound_name,
         ai.thing_id,t.x::real,t.y::real
  FROM player_pos p
  JOIN monster_ai ai ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND NOT h.alive
  -- A_XScream: a gibbed actor slops instead of crying out.
  JOIN thing_health hh ON hh.map_id=ai.map_id AND hh.thing_id=ai.thing_id
  JOIN thing_combat_defs cdx ON cdx.thing_type=t.type
  JOIN sound_pick sp ON sp.thing_type=t.type
   AND sp.cue = CASE WHEN hh.health < -hh.max_health
                      AND cdx.xdeath_frame IS NOT NULL
                     THEN 'xdeath'::sound_cue ELSE 'death'::sound_cue END
   AND sp.variant = doom_prandom(ai.thing_id, 0, 60) % sp.n

  UNION ALL
  -- Pain
  SELECT p.map_id,
         'mon-pain:'||ai.thing_id::text||':'||p.level_tic::text,p.level_tic,
         sp.sound_name,ai.thing_id,t.x::real,t.y::real
  FROM player_pos p
  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state='pain'
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_ai_frames f ON f.thing_type=t.type AND f.state='pain'
   AND f.seq_index=ai.seq_index AND ai.state_tics=f.tics
  JOIN sound_pick sp ON sp.thing_type=t.type AND sp.cue='pain'
   AND sp.variant = doom_prandom(ai.thing_id, 0, 60) % sp.n
  UNION ALL
  -- Chase
  SELECT p.map_id,
         'mon-act:'||ai.thing_id::text||':'||p.level_tic::text,p.level_tic,
         sp.sound_name,ai.thing_id,t.x::real,t.y::real
  FROM player_pos p
  JOIN monster_ai ai ON ai.map_id=p.map_id AND ai.state='see'
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_health h ON h.map_id=ai.map_id AND h.thing_id=ai.thing_id
   AND h.alive
  JOIN sound_pick sp ON sp.thing_type=t.type AND sp.cue='active'
   AND sp.variant = doom_prandom(ai.thing_id, 0, 60) % sp.n
  WHERE (doom_prandom(ai.thing_id, p.level_tic, 61) * 256
         + doom_prandom(ai.thing_id, p.level_tic, 62)) % active_sound_odds = 0
  UNION ALL
  -- Player pain
  SELECT p.map_id,
         'plr-pain:'||p.player_thing_id::text||':'||(p.level_tic - (12 - ps.pain_face_tics))::text,
         p.level_tic,sp.sound_name,p.player_thing_id,p.px,p.py
  FROM player_pos p
  JOIN player_state ps ON ps.map_id=p.map_id
   AND ps.player_thing_id=p.player_thing_id
  JOIN sound_pick sp ON sp.thing_type=1 AND sp.cue='pain' AND sp.variant=0
  WHERE ps.alive AND ps.pain_face_tics > 0

  UNION ALL
  -- Player death
  SELECT p.map_id,'plr-death:'||p.player_thing_id::text,p.level_tic,sp.sound_name,
         p.player_thing_id,p.px,p.py
  FROM player_pos p
  JOIN player_state ps ON ps.map_id=p.map_id
   AND ps.player_thing_id=p.player_thing_id
  JOIN sound_pick sp ON sp.thing_type=1 AND sp.cue='death' AND sp.variant=0
  WHERE NOT ps.alive
)
INSERT INTO sound_events
  (map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y)
SELECT map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y
FROM events WHERE sound_name IS NOT NULL
ON CONFLICT (map_id,event_key) DO NOTHING;

-- doom_cs_projectiles has consumed monster firing flags before this runs.
-- Clear them here so a held attack frame cannot emit the same sound on more
-- than one physics tic before doom_cs_monsters advances again.
UPDATE monster_ai SET fired_this_tick=FALSE
WHERE map_id=p_map_id AND fired_this_tick;

let mut level_tic = -1;
SELECT ps.level_tics AS t FROM player_state ps
WHERE ps.map_id = p_map_id AND ps.player_thing_id = p_player_thing_id
{ level_tic = t; }
if level_tic >= 0 AND level_tic % sound_trim_interval = 0 {
  DELETE FROM sound_events e
  WHERE e.map_id = p_map_id
    AND e.level_tic < (SELECT COALESCE(MAX(ps.level_tics), 0) - sound_trim_age
                       FROM player_state ps
                       JOIN mp_players mp ON mp.map_id = ps.map_id
                        AND mp.player_thing_id = ps.player_thing_id
                       WHERE mp.map_id = p_map_id)
    AND e.event_key NOT LIKE 'mon-sight:%'
    AND e.event_key NOT LIKE 'mon-death:%'
    AND e.event_key NOT LIKE 'plr-death:%';
}
$doom$;
