CREATE OR REPLACE FUNCTION doom_cs_hitscan_apply(p_map_id integer, p_player_thing_id integer, p_shot_serial bigint) RETURNS boolean
LANGUAGE cedarscript AS $doom$
let dropped_base = doom_const('DROPPED_THING_ID_BASE');
-- Apply and retire one blast's staged traces.
-- Shared by every hitscan weapon
UPDATE thing_health h
SET health = h.health - d.damage,
    alive = h.health - d.damage > 0
FROM (
  SELECT map_id, thing_id, SUM(damage)::int AS damage
  FROM hitscan_hits
  WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id AND shot_serial=p_shot_serial
    AND hit_kind='target'
  GROUP BY map_id, thing_id
) d
WHERE h.map_id=d.map_id AND h.thing_id=d.thing_id;

-- Pellets that hit another player. Their health lives in player_state, so the
-- UPDATE above never sees them; the same P_DamageMobj arithmetic applies:
-- sk_baby halves it, armour takes its third or half, god mode refuses it
-- but still takes the shove, and a killing blow names the shooter for
-- doom_mp_frags. The chainsaw shoves nobody.
WITH hits AS (
  SELECT hh.thing_id AS victim_id, SUM(hh.damage)::int AS raw,
         MAX(hh.px)::float8 AS sx, MAX(hh.py)::float8 AS sy
  FROM hitscan_hits hh
  JOIN player_state v ON v.map_id=hh.map_id AND v.player_thing_id=hh.thing_id
  WHERE hh.map_id=p_map_id AND hh.player_thing_id=p_player_thing_id
    AND hh.shot_serial=p_shot_serial AND hh.hit_kind='target' AND hh.damage>0
  GROUP BY hh.thing_id
),
scaled AS (
  SELECT h.victim_id, h.sx, h.sy,
         h.raw >> CASE WHEN g.skill=0 THEN 1 ELSE 0 END AS dmg,
         v.armor, v.armor_class, v.god_mode OR v.invuln_tics>0 AS blocked,
         vt.x::float8 AS vx, vt.y::float8 AS vy, pw.current_weapon
  FROM hits h
  JOIN player_state v ON v.map_id=p_map_id AND v.player_thing_id=h.victim_id
  JOIN game_tic_commands g ON g.map_id=v.map_id AND g.player_thing_id=v.player_thing_id
  JOIN things vt ON vt.map_id=v.map_id AND vt.id=v.player_thing_id
  JOIN player_weapons pw ON pw.map_id=p_map_id AND pw.player_thing_id=p_player_thing_id
),
applied AS (
  SELECT s.*,
         CASE WHEN s.blocked THEN 0
              ELSE LEAST(s.armor, CASE s.armor_class WHEN 2 THEN FLOOR(s.dmg/2.0)::int
                                                     WHEN 1 THEN FLOOR(s.dmg/3.0)::int
                                                     ELSE 0 END) END AS saved,
         CASE WHEN s.current_weapon=8 OR s.dist=0 THEN 0.0
              ELSE s.dmg*0.125*(s.vx-s.sx)/s.dist END AS thrust_x,
         CASE WHEN s.current_weapon=8 OR s.dist=0 THEN 0.0
              ELSE s.dmg*0.125*(s.vy-s.sy)/s.dist END AS thrust_y
  FROM (SELECT sc.*, SQRT(POWER(sc.vx-sc.sx,2)+POWER(sc.vy-sc.sy,2)) AS dist
        FROM scaled sc) s
)
UPDATE player_state ps
SET armor = ps.armor - a.saved,
    armor_class = CASE WHEN ps.armor-a.saved<=0 THEN 0 ELSE ps.armor_class END,
    health = GREATEST(0, ps.health - CASE WHEN a.blocked THEN 0 ELSE a.dmg-a.saved END),
    damage_count = LEAST(100, ps.damage_count + CASE WHEN a.blocked THEN 0 ELSE a.dmg-a.saved END),
    alive = GREATEST(0, ps.health - CASE WHEN a.blocked THEN 0 ELSE a.dmg-a.saved END) > 0,
    pain_face_tics = CASE WHEN NOT a.blocked AND a.dmg-a.saved > 0 THEN 12 ELSE ps.pain_face_tics END,
    killer_id = CASE WHEN ps.alive AND NOT a.blocked
                          AND ps.health - (a.dmg-a.saved) <= 0
                     THEN p_player_thing_id::int ELSE ps.killer_id END,
    momentum_x = (ps.momentum_x + a.thrust_x)::real,
    momentum_y = (ps.momentum_y + a.thrust_y)::real
FROM applied a
WHERE ps.map_id=p_map_id AND ps.player_thing_id=a.victim_id;

-- P_DamageMobj's thrust, for bullets. P_LineAttack passes the shooter as the
-- inflictor, so the shove is along the line from the player to the target:
-- `thrust = damage*12.5/mass` map units a tic.
--
-- Except with the chainsaw. Vanilla skips the thrust when the source is a
-- player holding one -- `source->player->readyweapon != wp_chainsaw` -- which
-- is exactly why a chainsaw holds an enemy in place instead of pushing it out
-- of reach while it grinds.
UPDATE things t
SET mom_x = (t.mom_x + s.push * s.dx / s.dist)::real,
    mom_y = (t.mom_y + s.push * s.dy / s.dist)::real
FROM (
  SELECT hh.thing_id,
         SUM(hh.damage) * 12.5 / GREATEST(1, cd.mass) AS push,
         (v.x - pt.x)::float8 AS dx, (v.y - pt.y)::float8 AS dy,
         NULLIF(SQRT(POWER(v.x-pt.x,2)+POWER(v.y-pt.y,2)),0)::float8 AS dist
  FROM hitscan_hits hh
  JOIN things v ON v.map_id=hh.map_id AND v.id=hh.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=v.type
  JOIN things pt ON pt.map_id=hh.map_id AND pt.id=p_player_thing_id::int
  JOIN player_weapons pw ON pw.map_id=hh.map_id
   AND pw.player_thing_id=p_player_thing_id::int
  WHERE hh.map_id=p_map_id AND hh.player_thing_id=p_player_thing_id
    AND hh.shot_serial=p_shot_serial AND hh.hit_kind='target' AND hh.damage>0
    AND pw.current_weapon <> 8
    -- A player victim's shove goes to player_state (below), not their Thing.
    AND NOT EXISTS (SELECT 1 FROM player_state ps
                    WHERE ps.map_id=hh.map_id AND ps.player_thing_id=hh.thing_id)
  GROUP BY hh.thing_id, cd.mass, v.x, v.y, pt.x, pt.y
) s
WHERE t.map_id=p_map_id AND t.id=s.thing_id AND s.dist IS NOT NULL;

-- Roll pain independently for every damaging pellet.
-- Any successful roll puts a surviving actor into its pain state. Getting shot still
-- alerts an actor even when the pain roll fails
WITH pain_rolls AS (
  SELECT hh.map_id,hh.thing_id,t.type,
         BOOL_OR(doom_prandom(hh.thing_id, p_shot_serial, 1)
                   < cd.pain_chance) AS flinches
  FROM hitscan_hits hh
  JOIN things t ON t.map_id=hh.map_id AND t.id=hh.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=t.type
  WHERE hh.map_id=p_map_id AND hh.player_thing_id=p_player_thing_id AND hh.shot_serial=p_shot_serial
    AND hh.hit_kind='target' AND hh.damage>0
  GROUP BY hh.map_id,hh.thing_id,t.type
)
UPDATE monster_ai ai
SET state=CASE WHEN hit.flinches THEN 'pain' ELSE 'see' END,
    seq_index=CASE WHEN hit.flinches THEN 0 ELSE ai.seq_index END,
    state_tics=CASE WHEN hit.flinches THEN COALESCE(fp.tics,ai.state_tics)
                    ELSE COALESCE(fs.tics,ai.state_tics) END
FROM pain_rolls hit
JOIN thing_health h ON h.map_id = hit.map_id AND h.thing_id = hit.thing_id
LEFT JOIN thing_ai_frames fp ON fp.thing_type=hit.type
  AND fp.state='pain' AND fp.seq_index=0
LEFT JOIN thing_ai_frames fs ON fs.thing_type=hit.type
  AND fs.state='see' AND fs.seq_index=0
WHERE ai.map_id = hit.map_id AND ai.thing_id = hit.thing_id
  AND h.alive AND ai.state NOT IN ('die','dead')
  AND NOT EXISTS (SELECT 1 FROM thing_combat_defs bd
                  WHERE bd.thing_type = hit.type AND bd.explodes)
  -- A failed pain roll still alerts a dormant monster, but must not reset an
  -- actor that is already chasing or attacking.
  AND (hit.flinches OR ai.state='stand');

INSERT INTO world_effects
  (map_id,effect_id,effect_type,x,y,z,sector_id,age)
SELECT map_id,shot_serial*16+pellet,
       CASE WHEN hit_kind='target' AND NOT no_blood THEN 'blood' ELSE 'puff' END,
       px+GREATEST(0.0,distance-CASE WHEN hit_kind='target' THEN 10 ELSE 4 END)*COS(angle),
       py+GREATEST(0.0,distance-CASE WHEN hit_kind='target' THEN 10 ELSE 4 END)*SIN(angle),
       shoot_z+slope*GREATEST(0.0,distance-CASE WHEN hit_kind='target' THEN 10 ELSE 4 END),
       sector_id,0
FROM hitscan_hits
WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id AND shot_serial=p_shot_serial
ON CONFLICT (map_id,effect_id) DO UPDATE
SET effect_type=EXCLUDED.effect_type,x=EXCLUDED.x,y=EXCLUDED.y,z=EXCLUDED.z,
    sector_id=EXCLUDED.sector_id,age=0;

-- Vanilla only has a couple of monsters drop anything on death (everything
-- else, including the imp, drops nothing): zombieman -> a clip, sergeant -> a shotgun.
WITH just_died AS (
  SELECT DISTINCT hh.map_id, hh.thing_id
  FROM hitscan_hits hh
  JOIN thing_health th ON th.map_id = hh.map_id AND th.thing_id = hh.thing_id
  WHERE hh.map_id = p_map_id AND hh.player_thing_id = p_player_thing_id AND hh.shot_serial = p_shot_serial
    AND hh.hit_kind = 'target' AND NOT th.alive
),
drops AS (
  SELECT jd.map_id, jd.thing_id AS source_thing_id, t.x, t.y, t.angle,
         cd.drops_thing_type AS drop_type
  FROM just_died jd
  JOIN things t ON t.map_id = jd.map_id AND t.id = jd.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
   AND cd.drops_thing_type IS NOT NULL
)
-- Dropped-item Things get a deterministic id well above any real WAD thing
INSERT INTO things (map_id, id, x, y, angle, spawn_x, spawn_y, spawn_angle, type, flags)
SELECT map_id, dropped_base + source_thing_id, x, y, angle, x, y, angle, drop_type, 7
FROM drops
ON CONFLICT (map_id, id) DO NOTHING;

WITH just_died AS (
  SELECT DISTINCT hh.map_id, hh.thing_id
  FROM hitscan_hits hh
  JOIN thing_health th ON th.map_id = hh.map_id AND th.thing_id = hh.thing_id
  WHERE hh.map_id = p_map_id AND hh.player_thing_id = p_player_thing_id AND hh.shot_serial = p_shot_serial
    AND hh.hit_kind = 'target' AND NOT th.alive
),
drops AS (
  SELECT jd.map_id, jd.thing_id AS source_thing_id,
         COALESCE(ai.sector_id, rt.sector_id) AS sector_id,
         cd.drops_thing_type AS drop_type
  FROM just_died jd
  JOIN things t ON t.map_id = jd.map_id AND t.id = jd.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
   AND cd.drops_thing_type IS NOT NULL
  LEFT JOIN monster_ai ai ON ai.map_id = jd.map_id AND ai.thing_id = jd.thing_id
  LEFT JOIN render_things rt ON rt.map_id = jd.map_id AND rt.thing_id = jd.thing_id
)
INSERT INTO render_things
  (map_id, thing_id, sector_id, sprite, frame, fullbright, spawn_ceiling, thing_height)
SELECT d.map_id, dropped_base + d.source_thing_id, d.sector_id,
       ts.sprite, ts.frame, ts.fullbright, ts.spawn_ceiling, ts.thing_height
FROM drops d
JOIN thing_sprite_defs ts ON ts.thing_type = d.drop_type
WHERE d.sector_id IS NOT NULL
ON CONFLICT (map_id, thing_id) DO NOTHING;

-- Gun-activated linedefs, Doom's G1/GR.
INSERT INTO line_special_events
  (map_id,player_thing_id,line_id,trigger_type,from_front)
SELECT DISTINCT hh.map_id,hh.player_thing_id,hh.line_id,'shoot',
       COALESCE(hh.line_from_front,TRUE)
FROM hitscan_hits hh
JOIN linedefs ld ON ld.map_id=hh.map_id AND ld.id=hh.line_id
JOIN line_special_defs d ON d.special=ld.special AND d.shoot_activated
WHERE hh.map_id=p_map_id AND hh.player_thing_id=p_player_thing_id
  AND hh.shot_serial=p_shot_serial
  AND hh.hit_kind='wall'
ON CONFLICT (map_id,player_thing_id,line_id,trigger_type) DO NOTHING;

DELETE FROM hitscan_hits
WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id AND shot_serial=p_shot_serial;
let mut special = false;
SELECT 0::int,
       EXISTS (SELECT 1 FROM line_special_events e
               WHERE e.map_id=p_map_id AND e.player_thing_id=p_player_thing_id
                 AND e.trigger_type='shoot') AS special_queued
{ special = special_queued; }
return special;
$doom$;
