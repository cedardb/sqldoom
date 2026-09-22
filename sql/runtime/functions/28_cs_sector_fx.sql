CREATE OR REPLACE FUNCTION doom_cs_sector_fx(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let damage_interval = doom_const('DAMAGE_FLOOR_INTERVAL');
-- Sector specials: damaging floors.
UPDATE player_state ps
SET god_mode=FALSE
FROM sectors s
JOIN sector_special_defs sd ON sd.special=s.special AND sd.ends_level_at_low_health
WHERE s.map_id=ps.map_id AND s.id=ps.sector_id
  AND ps.map_id=p_map_id::int AND ps.player_thing_id=p_player_thing_id::int
  AND ps.god_mode;

-- Damaging floors. Doom applies these once every 32 tics while the player
-- stands in the sector: nukage 5, slime 10, and the harsher 20% variants.
-- A radiation suit blocks them outright here; vanilla still lets the 20%
-- floors through one time in sixteen, which is not modelled.
UPDATE player_state ps
SET armor = ps.armor - d.saved,
    armor_class = CASE WHEN ps.armor - d.saved <= 0 THEN 0
                       ELSE ps.armor_class END,
    health = GREATEST(0, ps.health - (d.amount - d.saved)),
    -- P_DamageMobj: player->damagecount += damage, which reddens the screen.
    damage_count = LEAST(100, ps.damage_count + (d.amount - d.saved)),
    pain_face_tics = 12,
    alive = (ps.health - (d.amount - d.saved)) > 0,
    -- The floor is the world, for the deathmatch scoreboard.
    killer_id = CASE WHEN (ps.health - (d.amount - d.saved)) <= 0 THEN -1
                     ELSE ps.killer_id END
FROM (
  SELECT s.map_id, s.id AS sector_id, ps2.player_thing_id, k.amount,
         LEAST(ps2.armor, CASE ps2.armor_class
                            WHEN 2 THEN FLOOR(k.amount/2.0)::int
                            WHEN 1 THEN FLOOR(k.amount/3.0)::int
                            ELSE 0 END) AS saved
  FROM sectors s
  JOIN sector_special_defs sd ON sd.special=s.special
   AND sd.damage_per_hit IS NOT NULL
  CROSS JOIN LATERAL (
    SELECT sd.damage_per_hit
           >> CASE WHEN (SELECT g.skill FROM game_tic_commands g
                     WHERE g.map_id=p_map_id::int
                       AND g.player_thing_id=p_player_thing_id::int)=0 THEN 1 ELSE 0 END AS amount
  ) k
  JOIN player_state ps2 ON ps2.map_id = s.map_id
   AND ps2.player_thing_id = p_player_thing_id::int
  WHERE s.map_id=p_map_id
) d
WHERE ps.map_id=d.map_id AND ps.player_thing_id=d.player_thing_id
  AND ps.sector_id=d.sector_id
  AND ps.alive AND ps.radsuit_tics<=0
  -- God mode and invulnerability stop damage at the source.
  AND NOT ps.god_mode AND ps.invuln_tics <= 0
  AND (ps.level_tics % damage_interval)=0;
$doom$;
