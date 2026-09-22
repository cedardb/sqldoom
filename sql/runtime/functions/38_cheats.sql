CREATE OR REPLACE FUNCTION doom_cheat(p_map_id integer, p_player_thing_id integer, p_code text) RETURNS text
LANGUAGE cedarscript AS $doom$
-- Apply one typed cheat code and return the message Doom prints for it.
--
-- (p_local.h): INVULNTICS 30 s, INVISTICS and IRONTICS 60 s, INFRATICS 120 s.
let mut message = '';
let mut code = UPPER(p_code::text);

if code = 'IDDQD' {
  UPDATE player_state SET god_mode = NOT god_mode
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;
  SELECT CASE WHEN god_mode THEN 'Degreelessness Mode ON'
              ELSE 'Degreelessness Mode OFF' END AS m
  FROM player_state
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int
  { message = m; }
}
-- IDSPISPOPD is Doom 1's spelling, IDCLIP Doom 2's. Both are accepted.
if code = 'IDCLIP' OR code = 'IDSPISPOPD' {
  UPDATE player_state SET noclip = NOT noclip
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;
  SELECT CASE WHEN noclip THEN 'No Clipping Mode ON'
              ELSE 'No Clipping Mode OFF' END AS m
  FROM player_state
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int
  { message = m; }
}
if code = 'IDFA' OR code = 'IDKFA' {
  -- The arsenal itself is the same one the menu cheat grants.
  let mut ignored = doom_cheat_arsenal(p_map_id, p_player_thing_id);
  message = 'Ammo (no keys) Added';
}
if code = 'IDKFA' {
  UPDATE player_state SET key_red=TRUE, key_blue=TRUE, key_yellow=TRUE
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;
  message = 'Very Happy Ammo Added';
}
if code = 'IDBEHOLDV' {
  UPDATE player_state SET invuln_tics=1050
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;
  message = 'Invulnerability';
}
if code = 'IDBEHOLDS' {
  UPDATE player_state SET berserk=TRUE, health=GREATEST(health,100)
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;
  message = 'Berserk';
}
if code = 'IDBEHOLDI' {
  UPDATE player_state SET invis_tics=2100
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;
  message = 'Partial Invisibility';
}
if code = 'IDBEHOLDR' {
  UPDATE player_state SET radsuit_tics=2100
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;
  message = 'Radiation Suit';
}
if code = 'IDBEHOLDA' {
  UPDATE player_state SET power_map=TRUE
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;
  message = 'Computer Area Map';
}
if code = 'IDBEHOLDL' {
  UPDATE player_state SET light_amp_tics=4200
  WHERE map_id=p_map_id::int AND player_thing_id=p_player_thing_id::int;
  message = 'Light Amplification Visor';
}
if code = 'IDCHOPPERS' {
  INSERT INTO player_weapon_owned (map_id, player_thing_id, weapon_id)
  VALUES (p_map_id::int, p_player_thing_id::int, 8)
  ON CONFLICT DO NOTHING;
  message = '... doesn''t suck - GM';
}
if code = 'IDMYPOS' {
  -- Vanilla prints these as raw fixed-point hex, which is unreadable; map
  -- units rounded to whole numbers say the same thing.
  SELECT 'ang=' || ROUND(t.angle)::int::text
      || '; x,y=(' || ROUND(t.x)::int::text
      || ',' || ROUND(t.y)::int::text || ')' AS m
  FROM things t
  WHERE t.map_id=p_map_id::int AND t.id=p_player_thing_id::int
  { message = m; }
}
return message;
$doom$;

-- ST_Responder: every letter typed in the level goes into a buffer, matched
-- against the sequences from the end. Returns what the client has to act on:
-- 'msg:<text>' (a cheat above was applied), 'warp:ExMy' (IDCLEV), 'music:ExMy'
-- (IDMUS), 'iddt' (the automap's own toggle), or 'none'.
CREATE OR REPLACE FUNCTION doom_cheat_key(p_map_id integer, p_player_thing_id integer, p_key text) RETURNS text
LANGUAGE cedarscript AS $doom$
UPDATE screen_state SET cheat_buffer = RIGHT(cheat_buffer || UPPER(p_key), 12) WHERE id=0;
let mut buf = '';
SELECT cheat_buffer AS b FROM screen_state WHERE id=0 { buf = b; }
let mut result = 'none';
SELECT CASE
  WHEN SUBSTRING(buf FROM LENGTH(buf)-7 FOR 6) = 'IDCLEV'
       AND SUBSTRING(buf FROM LENGTH(buf)-1 FOR 1) BETWEEN '1' AND '9'
       AND RIGHT(buf,1) BETWEEN '1' AND '9'
    THEN 'warp:E' || SUBSTRING(buf FROM LENGTH(buf)-1 FOR 1) || 'M' || RIGHT(buf,1)
  WHEN SUBSTRING(buf FROM LENGTH(buf)-6 FOR 5) = 'IDMUS'
       AND SUBSTRING(buf FROM LENGTH(buf)-1 FOR 1) BETWEEN '1' AND '9'
       AND RIGHT(buf,1) BETWEEN '1' AND '9'
    THEN 'music:E' || SUBSTRING(buf FROM LENGTH(buf)-1 FOR 1) || 'M' || RIGHT(buf,1)
  WHEN RIGHT(buf,4) = 'IDDT' THEN 'iddt'
  ELSE COALESCE((
    SELECT 'code:' || c.code
    FROM (VALUES ('IDSPISPOPD'),('IDCHOPPERS'),('IDBEHOLDV'),('IDBEHOLDS'),
                 ('IDBEHOLDI'),('IDBEHOLDR'),('IDBEHOLDA'),('IDBEHOLDL'),
                 ('IDMYPOS'),('IDCLIP'),('IDKFA'),('IDDQD'),('IDFA')) AS c(code)
    WHERE buf LIKE '%' || c.code
    ORDER BY LENGTH(c.code) DESC, c.code LIMIT 1), 'none')
END AS r { result = r; }
if result LIKE 'code:%' {
  let code = SUBSTRING(result FROM 6);
  let msg = doom_cheat(p_map_id, p_player_thing_id, code);
  result = 'msg:' || msg;
}
if result <> 'none' {
  UPDATE screen_state SET cheat_buffer='' WHERE id=0;
}
return result;
$doom$;
