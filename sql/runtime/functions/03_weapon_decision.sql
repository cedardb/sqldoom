CREATE OR REPLACE VIEW doom_weapon_decision AS
-- Advance the player's weapon psprite state machine one 35 Hz tic: up/down
-- (switching), ready (idle bob), fire (attack sequence with vanilla-style
-- refire), and an independent muzzle-flash overlay sequence.
-- Params: map_id, player_thing_id.
WITH
input AS (
  SELECT g.map_id,g.player_thing_id,g.attack_held,
         COALESCE(g.weapon_switch_to,pg.weapon_id) AS switch_to,
         ps.bob_strength AS bob,ps.level_tics::int AS level_tic
  FROM game_tic_commands g
  JOIN player_state ps ON ps.map_id=g.map_id
    AND ps.player_thing_id=g.player_thing_id
  LEFT JOIN (
    SELECT map_id,player_thing_id,MIN(weapon_id) AS weapon_id
    FROM pickup_grants GROUP BY map_id,player_thing_id
  ) pg ON pg.map_id=g.map_id AND pg.player_thing_id=g.player_thing_id
),
current AS (
  SELECT pw.*, wd.ammo_type, wd.ammo_per_shot, i.attack_held, i.switch_to,
         i.bob, i.level_tic
  FROM input i
  JOIN player_weapons pw
    ON pw.map_id = i.map_id AND pw.player_thing_id = i.player_thing_id
  JOIN weapon_defs wd ON wd.weapon_id = pw.current_weapon
),
ammo AS (
  SELECT c.*,
    (CASE c.ammo_type
       WHEN 'bullets' THEN ps.ammo_bullets
       WHEN 'shells'  THEN ps.ammo_shells
       WHEN 'rockets' THEN ps.ammo_rockets
       WHEN 'cells'   THEN ps.ammo_cells
       ELSE 999999
     END >= c.ammo_per_shot) AS has_ammo
  FROM current c
  JOIN player_state ps ON ps.map_id = c.map_id AND ps.player_thing_id = c.player_thing_id
),
switch AS (
  SELECT a.*,
    (a.switch_to IS NOT NULL AND a.switch_to <> a.current_weapon
     AND own.weapon_id IS NOT NULL) AS switch_requested
  FROM ammo a
  LEFT JOIN player_weapon_owned own
    ON own.map_id = a.map_id AND own.player_thing_id = a.player_thing_id
   AND own.weapon_id = a.switch_to
),
frames AS (
  SELECT s.*,
         ready0.tics AS ready_tics,
         fire0.tics AS fire0_tics, fire0.is_attack_frame AS fire0_attack,
         nextf.seq_index AS next_seq, nextf.tics AS next_tics,
         nextf.is_attack_frame AS next_attack, nextf.refire_check AS next_refire,
         flash0.tics AS flash0_tics,
         flashnext.seq_index AS flashnext_seq, flashnext.tics AS flashnext_tics
  FROM switch s
  LEFT JOIN weapon_frames ready0
    ON ready0.weapon_id = s.current_weapon AND ready0.state = 'ready' AND ready0.seq_index = 0
  LEFT JOIN weapon_frames fire0
    ON fire0.weapon_id = s.current_weapon AND fire0.state = 'fire' AND fire0.seq_index = 0
  LEFT JOIN weapon_frames nextf
    ON nextf.weapon_id = s.current_weapon AND nextf.state = 'fire' AND nextf.seq_index = s.seq_index + 1
  LEFT JOIN weapon_frames flash0
    ON flash0.weapon_id = s.current_weapon AND flash0.state = 'flash' AND flash0.seq_index = 0
  LEFT JOIN weapon_frames flashnext
    ON flashnext.weapon_id = s.current_weapon AND flashnext.state = 'flash'
   AND flashnext.seq_index = s.flash_seq_index + 1
),
flags AS (
  SELECT f.*,
    (f.state = 'fire' AND f.tics <= 1) AS advancing,
    (f.state = 'fire' AND f.tics <= 1 AND f.next_seq IS NULL) AS falls_off,
    (f.state = 'fire' AND f.tics <= 1 AND f.next_seq IS NOT NULL
       AND f.next_refire AND f.attack_held AND f.has_ammo) AS refires,
    (f.state = 'ready' AND f.attack_held AND f.has_ammo
       AND NOT f.switch_requested) AS starts_fire,
    (f.state = 'down' AND f.sy + 6.0 >= 128.0) AS down_done,
    (f.state = 'up' AND f.sy - 6.0 <= 32.0) AS up_done,
    (f.flash_seq_index IS NOT NULL AND f.flash_tics <= 1) AS flash_advancing
  FROM frames f
),
decision AS (
  SELECT fl.*,
    CASE
      WHEN fl.switch_requested THEN 'down'::weapon_state
      WHEN fl.state = 'down' THEN CASE WHEN fl.down_done THEN 'up'::weapon_state ELSE 'down'::weapon_state END
      WHEN fl.state = 'up' THEN CASE WHEN fl.up_done THEN 'ready'::weapon_state ELSE 'up'::weapon_state END
      WHEN fl.state = 'ready' THEN CASE WHEN fl.starts_fire THEN 'fire'::weapon_state ELSE 'ready'::weapon_state END
      WHEN fl.state = 'fire' AND fl.advancing AND fl.falls_off THEN 'ready'::weapon_state
      ELSE fl.state
    END AS n_state,
    CASE
      WHEN fl.switch_requested THEN fl.seq_index
      WHEN fl.state = 'up' AND fl.up_done THEN 0
      WHEN fl.state = 'ready' THEN 0
      WHEN fl.state = 'fire' AND fl.advancing THEN
        CASE WHEN fl.falls_off OR fl.refires THEN 0 ELSE fl.next_seq END
      ELSE fl.seq_index
    END AS n_seq,
    CASE
      WHEN fl.switch_requested THEN fl.tics
      WHEN fl.state = 'up' THEN CASE WHEN fl.up_done THEN fl.ready_tics ELSE fl.tics END
      WHEN fl.state = 'ready' THEN
        CASE WHEN fl.starts_fire THEN fl.fire0_tics ELSE fl.tics END
      WHEN fl.state = 'fire' AND fl.advancing THEN
        CASE
          WHEN fl.falls_off THEN fl.ready_tics
          WHEN fl.refires THEN fl.fire0_tics
          ELSE fl.next_tics
        END
      WHEN fl.state = 'fire' THEN fl.tics - 1
      ELSE fl.tics
    END AS n_tics,
    -- fires_now: true only the single tic an is_attack_frame row is entered.
    (
      (fl.state = 'ready' AND fl.starts_fire AND fl.fire0_attack IS TRUE)
      OR (fl.state = 'fire' AND fl.advancing AND NOT fl.falls_off
          AND NOT fl.refires AND fl.next_attack IS TRUE)
      -- A_ReFire jumps straight back to fire/0. If that first state owns the
      -- action pointer (chaingun/plasma/chainsaw), entering it fires now too.
      OR (fl.state = 'fire' AND fl.advancing AND fl.refires
          AND fl.fire0_attack IS TRUE)
    ) AS fires_now,
    CASE WHEN fl.state = 'down' AND fl.down_done AND NOT fl.switch_requested
         THEN fl.pending_weapon ELSE fl.current_weapon END AS n_current_weapon,
    CASE
      WHEN fl.switch_requested THEN fl.switch_to
      WHEN fl.state = 'down' AND fl.down_done THEN NULL
      ELSE fl.pending_weapon
    END AS n_pending_weapon
  FROM flags fl
),
decision2 AS (
  SELECT d.*,
    CASE WHEN d.n_state = 'ready' THEN 1.0 + d.bob * COS(2.0*PI()*(d.level_tic % 64)/64.0)
         ELSE d.sx END AS n_sx,
    CASE
      WHEN d.n_state = 'ready' THEN 32.0 + d.bob * SIN(2.0*PI()*(d.level_tic % 32)/64.0)
      WHEN d.n_state = 'down' THEN LEAST(128.0, d.sy + 6.0)
      WHEN d.n_state = 'up' THEN GREATEST(32.0, d.sy - 6.0)
      ELSE d.sy
    END AS n_sy,
    CASE
      WHEN d.fires_now THEN CASE WHEN d.flash0_tics IS NOT NULL THEN 0 END
      WHEN d.flash_seq_index IS NULL THEN NULL
      WHEN NOT d.flash_advancing THEN d.flash_seq_index
      ELSE d.flashnext_seq
    END AS n_flash_seq,
    CASE
      WHEN d.fires_now THEN COALESCE(d.flash0_tics, 0)
      WHEN d.flash_seq_index IS NULL THEN 0
      WHEN NOT d.flash_advancing THEN d.flash_tics - 1
      ELSE COALESCE(d.flashnext_tics, 0)
    END AS n_flash_tics
  FROM decision d
)
SELECT map_id,player_thing_id,n_state,n_seq,n_tics,n_current_weapon,
       n_pending_weapon,n_flash_seq,n_flash_tics,n_sx,n_sy,fires_now
FROM decision2;
