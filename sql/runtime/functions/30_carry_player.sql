CREATE OR REPLACE FUNCTION doom_carry_player(p_from_map_id integer, p_from_player_thing_id integer, p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
-- Carry the player across a level exit, the way vanilla does.
--
-- G_PlayerFinishLevel keeps weapons, ammo, armor, backpack and health -- it
-- does NOT top health up  and clears only powerups, keys and the screen effects.
UPDATE player_state ps
SET health=src.health,
    armor=src.armor, armor_class=src.armor_class, backpack=src.backpack,
    ammo_bullets=src.ammo_bullets, ammo_shells=src.ammo_shells,
    ammo_rockets=src.ammo_rockets, ammo_cells=src.ammo_cells
FROM player_state src
WHERE ps.map_id=p_map_id::int AND ps.player_thing_id=p_player_thing_id::int
  AND src.map_id=p_from_map_id::int
  AND src.player_thing_id=p_from_player_thing_id::int
  -- A dead player gets the reborn loadout, so carry nothing.
  AND src.alive AND src.health>0;

DELETE FROM player_weapon_owned o
WHERE o.map_id=p_map_id::int AND o.player_thing_id=p_player_thing_id::int
  AND EXISTS (SELECT 1 FROM player_state src
              WHERE src.map_id=p_from_map_id::int
                AND src.player_thing_id=p_from_player_thing_id::int
                AND src.alive AND src.health>0);

INSERT INTO player_weapon_owned (map_id, player_thing_id, weapon_id)
SELECT p_map_id::int, p_player_thing_id::int, o.weapon_id
FROM player_weapon_owned o
JOIN player_state src
  ON src.map_id=o.map_id AND src.player_thing_id=o.player_thing_id
WHERE o.map_id=p_from_map_id::int
  AND o.player_thing_id=p_from_player_thing_id::int
  AND src.alive AND src.health>0
ON CONFLICT (map_id,player_thing_id,weapon_id) DO NOTHING;

-- Enter holding what you left with. The row keeps reset_stage's state='up'
-- and sy=128, so the weapon plays its raise animation on entry as it should.
UPDATE player_weapons pw
SET current_weapon=srcw.current_weapon
FROM player_weapons srcw
JOIN player_state src
  ON src.map_id=srcw.map_id AND src.player_thing_id=srcw.player_thing_id
WHERE pw.map_id=p_map_id::int AND pw.player_thing_id=p_player_thing_id::int
  AND srcw.map_id=p_from_map_id::int
  AND srcw.player_thing_id=p_from_player_thing_id::int
  AND src.alive AND src.health>0;
$doom$;
