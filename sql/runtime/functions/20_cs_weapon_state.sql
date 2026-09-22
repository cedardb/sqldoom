CREATE OR REPLACE FUNCTION doom_cs_weapon_state(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
UPDATE player_weapons w
SET state=d.n_state,seq_index=d.n_seq,tics=d.n_tics,
    current_weapon=d.n_current_weapon,pending_weapon=d.n_pending_weapon,
    flash_seq_index=d.n_flash_seq,flash_tics=d.n_flash_tics,
    sx=d.n_sx,sy=d.n_sy,
    shot_serial=w.shot_serial+CASE WHEN d.fires_now THEN 1 ELSE 0 END,
    fired_this_tick=d.fires_now
FROM doom_weapon_decision d
WHERE w.map_id=p_map_id AND w.player_thing_id=p_player_thing_id
  AND d.map_id=w.map_id AND d.player_thing_id=w.player_thing_id;
$doom$;
