-- Return the complete device-facing result of one fixed SQL tic. All flags in
-- this snapshot are derived from SQL state; the client uses them only to
-- publish a frame, play queued audio, or enter the intermission UI.
WITH
command AS (
  SELECT * FROM game_tic_commands
  WHERE map_id=$1::int AND player_thing_id=$2::int
),
cross_exit AS (
  SELECT COALESCE(BOOL_OR(d.is_exit),FALSE) AS requested,
         COALESCE(BOOL_OR(d.secret_exit),FALSE) AS secret
  FROM line_special_events e
  JOIN command c ON c.map_id=e.map_id AND c.player_thing_id=e.player_thing_id
  JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
  JOIN line_special_defs d ON d.special=ld.special
  WHERE e.trigger_type='cross'
),
-- Two exits the world takes by itself, with no line for the player to touch.
--
-- P_PlayerInSpecialSector case 11: the boss floor damages until it has worn
-- the player down, and then ends the level rather than killing them. E1M8 has
-- no exit linedef at all -- this is the only way off it.
-- Not conditional on being alive. Vanilla damages and then asks
-- `if (player->health <= 10) G_ExitLevel();` in the same breath, so the tic
-- that takes the player from 20 to 0 still ends the level -- and unarmoured
-- 20s step 100, 80, 60, 40, 20, 0 without ever landing inside 1..10. Requiring
-- alive here meant the boss floor ground the player to death on E1M8 instead
-- of finishing the episode.
sector_exit AS (
  SELECT COALESCE(BOOL_OR(ps.health<=sd.exit_at_health),FALSE) AS requested
  FROM command c
  JOIN player_state ps ON ps.map_id=c.map_id
    AND ps.player_thing_id=c.player_thing_id
  JOIN sectors s ON s.map_id=ps.map_id AND s.id=ps.sector_id
  LEFT JOIN sector_special_defs sd ON sd.special=s.special
),
-- A_BossDeath's other action: on E2M8 and E3M8 the level ends the moment the
-- last boss dies. Grouping inside the subquery is what keeps this false on an
-- ordinary map -- "no live bosses" is trivially true where there are none.
boss_exit AS (
  SELECT COALESCE(MAX(CASE WHEN q.alive_bosses=0 THEN 1 ELSE 0 END),0)=1
           AS requested
  FROM (
    SELECT SUM(CASE WHEN h.alive THEN 1 ELSE 0 END) AS alive_bosses
    FROM command c
    JOIN boss_actions ba ON ba.action='exit_level'
    JOIN maps m ON m.name=ba.map_name AND m.map_id=c.map_id
    JOIN things t ON t.map_id=m.map_id AND t.type=ba.boss_type
    JOIN thing_health h ON h.map_id=t.map_id AND h.thing_id=t.id
    GROUP BY ba.map_name
  ) q
)
SELECT
  ps.position_x,ps.position_y,ps.view_angle,ps.view_z,ps.alive,
  COALESCE(ur.locked,FALSE) AS use_locked,
  CASE WHEN COALESCE(ur.locked,FALSE) THEN usd.key_required::text END
    AS required_key,
  COALESCE(c.use_requested AND ur.eligible AND usd.is_exit,FALSE)
    AS use_exit,
  COALESCE(c.use_requested AND ur.eligible AND usd.secret_exit,FALSE)
    AS use_secret_exit,
  ce.requested AS cross_exit,ce.secret AS cross_secret_exit,
  se.requested AS sector_exit,be.requested AS boss_exit,
  -- The computer area map reveals the whole automap for the rest of the level.
  ps.power_map,
  -- Which doom_run_game_tic stages actually executed this tic.
  COALESCE(tt.stages,0) AS tic_stages,
  -- Which full-screen state SQL has up, and whether a demo is driving the
  -- input (39_flow.sql); the client mirrors both rather than deciding them.
  ss.screen,
  (ss.demo_playing IS NOT NULL) AS demo_active
FROM command c
CROSS JOIN screen_state ss
JOIN player_state ps ON ps.map_id=c.map_id
  AND ps.player_thing_id=c.player_thing_id
LEFT JOIN line_use_results ur ON ur.map_id=c.map_id
  AND ur.player_thing_id=c.player_thing_id
LEFT JOIN line_special_defs usd ON usd.special=ur.special
LEFT JOIN tic_trace tt ON tt.map_id=c.map_id
  AND tt.player_thing_id=c.player_thing_id
CROSS JOIN cross_exit ce
CROSS JOIN sector_exit se
CROSS JOIN boss_exit be;
