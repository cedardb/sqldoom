SELECT wd.weapon_id
FROM player_weapon_owned o
JOIN weapon_defs wd ON wd.weapon_id=o.weapon_id
JOIN player_weapons pw ON pw.map_id=o.map_id
  AND pw.player_thing_id=o.player_thing_id
WHERE o.map_id=$1 AND o.player_thing_id=$2 AND wd.slot=$3
ORDER BY CASE
  WHEN $3=1 AND pw.current_weapon=8 AND wd.weapon_id=1 THEN 0
  WHEN $3=1 AND pw.current_weapon<>8 AND wd.weapon_id=8 THEN 0
  WHEN wd.weapon_id=pw.current_weapon THEN 2 ELSE 1 END,
  wd.weapon_id DESC
LIMIT 1;
