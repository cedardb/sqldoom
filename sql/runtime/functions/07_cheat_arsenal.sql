CREATE OR REPLACE FUNCTION doom_cheat_arsenal(p_map_id integer, p_player_thing_id integer) RETURNS integer
LANGUAGE cedarscript AS $doom$
INSERT INTO player_weapon_owned (map_id,player_thing_id,weapon_id)
SELECT p_map_id,p_player_thing_id,w.weapon_id
FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8)) w(weapon_id)
ON CONFLICT (map_id,player_thing_id,weapon_id) DO NOTHING;
UPDATE player_state
SET ammo_bullets=(SELECT CASE WHEN backpack THEN ad.backpack_cap ELSE ad.cap END
                  FROM ammo_defs ad WHERE ad.ammo_type='bullets'),
    ammo_shells=(SELECT CASE WHEN backpack THEN ad.backpack_cap ELSE ad.cap END
                 FROM ammo_defs ad WHERE ad.ammo_type='shells'),
    ammo_rockets=(SELECT CASE WHEN backpack THEN ad.backpack_cap ELSE ad.cap END
                  FROM ammo_defs ad WHERE ad.ammo_type='rockets'),
    ammo_cells=(SELECT CASE WHEN backpack THEN ad.backpack_cap ELSE ad.cap END
                FROM ammo_defs ad WHERE ad.ammo_type='cells')
WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id;
return 7;
$doom$;
