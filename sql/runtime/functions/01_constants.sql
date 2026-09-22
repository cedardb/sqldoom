-- A named constant from doom_constants, for CedarScript to read into a
-- variable at function entry: let friction = doom_const('FRICTION');
CREATE OR REPLACE FUNCTION doom_const(p_name text) RETURNS double precision
LANGUAGE cedarscript AS $c$
let mut v = 0::double precision;
SELECT value AS x FROM doom_constants WHERE name = p_name { v = x; }
return v;
$c$;
