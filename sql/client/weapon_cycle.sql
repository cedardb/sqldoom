-- The next weapon the player owns, in Doom's slot order, wrapping at both
-- ends. $3 is +1 for the next and -1 for the previous. Slot 1 holds both the
-- fist and the chainsaw, so the cycle passes through each of them in turn
-- rather than treating the slot as one entry.
--
-- No row comes back when the current weapon is somehow not owned, which the
-- client reads as "leave the weapon alone".
WITH owned AS (
  SELECT wd.weapon_id,
         ROW_NUMBER() OVER (ORDER BY wd.slot, wd.weapon_id) AS pos,
         COUNT(*) OVER () AS n
  FROM player_weapon_owned o
  JOIN weapon_defs wd ON wd.weapon_id = o.weapon_id
  WHERE o.map_id = $1 AND o.player_thing_id = $2
),
here AS (
  SELECT o.pos, o.n
  FROM owned o
  JOIN player_weapons pw ON pw.map_id = $1 AND pw.player_thing_id = $2
   AND pw.current_weapon = o.weapon_id
)
SELECT o.weapon_id
FROM owned o CROSS JOIN here h
WHERE o.pos = ((h.pos - 1 + $3 + h.n) % h.n) + 1;
