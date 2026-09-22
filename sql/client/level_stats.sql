SELECT ls.map_id,m.name,ls.skill_bit,ls.level_tics,ls.par_tics,
       ls.kills,ls.total_kills,ls.items,ls.total_items,
       ls.secrets,ls.total_secrets,ls.secret_exit
FROM level_stats ls
JOIN maps m ON m.map_id=ls.map_id
WHERE ls.map_id=$1 AND ls.player_thing_id=$2 AND ls.completed;
