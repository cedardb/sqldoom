CREATE OR REPLACE FUNCTION doom_finish_level(p_map_id integer, p_player_thing_id integer, p_secret_exit boolean)
LANGUAGE cedarscript AS $doom$
-- Freeze the current run's authoritative SQL state for the intermission.
WITH params AS (
  SELECT p_map_id::int AS map_id,p_player_thing_id::int AS player_thing_id,
         p_secret_exit::boolean AS secret_exit
),
kill_count AS (
  SELECT count(*)::int AS value
  FROM params p
  JOIN thing_health h ON h.map_id=p.map_id AND NOT h.alive
  JOIN things t ON t.map_id=h.map_id AND t.id=h.thing_id
  JOIN thing_combat_defs d ON d.thing_type=t.type AND d.counts_kill
),
item_count AS (
  SELECT count(*)::int AS value
  FROM params p
  JOIN picked_up_items pi ON pi.map_id=p.map_id
  JOIN things t ON t.map_id=pi.map_id AND t.id=pi.thing_id
  WHERE EXISTS (
    SELECT 1 FROM pickup_defs d
    WHERE d.thing_type=t.type AND d.counts_item
  )
),
secret_count AS (
  SELECT count(*)::int AS value
  FROM params p
  JOIN level_secret_discoveries sd
    ON sd.map_id=p.map_id AND sd.player_thing_id=p.player_thing_id
)
UPDATE level_stats ls
SET level_tics=ps.level_tics,
    kills=k.value,items=i.value,secrets=s.value,
    completed=TRUE,secret_exit=p.secret_exit
FROM params p,kill_count k,item_count i,secret_count s,player_state ps
WHERE ls.map_id=p.map_id AND ls.player_thing_id=p.player_thing_id
  AND ps.map_id=p.map_id AND ps.player_thing_id=p.player_thing_id;
$doom$;
