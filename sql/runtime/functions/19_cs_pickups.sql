CREATE OR REPLACE FUNCTION doom_cs_pickups(p_map_id integer, p_player_thing_id integer)
LANGUAGE cedarscript AS $doom$
let pos_epsilon = doom_const('POS_EPSILON');
let pickup_reach = doom_const('PICKUP_REACH');
let dropped_base = doom_const('DROPPED_THING_ID_BASE');
let bonus_add = doom_const('BONUSADD');
let msg_tics = doom_const('MESSAGE_TICS');
-- Apply health/armor/ammo/weapon/key pickup.
-- Eligibility is staged before effects are applied so a pickup that fills a
-- stat is still removed, while an item that cannot help remains in the world.

-- Stage touched items
WITH params AS (
  SELECT ps.map_id,ps.position_x::float8 AS px,ps.position_y::float8 AS py,
         g.skill_bit AS skill,g.skill AS skill_level,ps.player_thing_id
  FROM player_state ps
  JOIN game_tic_commands g ON g.map_id=ps.map_id
    AND g.player_thing_id=ps.player_thing_id
  WHERE ps.map_id=p_map_id::int AND ps.player_thing_id=p_player_thing_id::int
    AND (ABS(ps.position_x-ps.previous_x)>pos_epsilon
      OR ABS(ps.position_y-ps.previous_y)>pos_epsilon)
),
eligible AS (
  SELECT t.id AS thing_id,t.type AS thing_type,d.kind,
         SQRT(POWER(t.x-p.px,2)+POWER(t.y-p.py,2)) AS dist
  FROM params p
  JOIN things t ON t.map_id=p.map_id
  JOIN pickup_defs d ON d.thing_type=t.type
  JOIN player_state ps ON ps.map_id=p.map_id
    AND ps.player_thing_id=p.player_thing_id
  WHERE (t.flags & p.skill)<>0 AND (t.flags & 16)=0
    AND SQRT(POWER(t.x-p.px,2)+POWER(t.y-p.py,2))<=pickup_reach
    AND NOT EXISTS (
      SELECT 1 FROM picked_up_items pu
      WHERE pu.map_id=t.map_id AND pu.thing_id=t.id
    )
    AND CASE
      WHEN d.kind='health' THEN
        NOT d.only_when_below_cap OR ps.health<d.cap
      -- Green/blue armor stays if its fixed point value is not an upgrade;
      -- armor bonuses are always consumed, including at 200 points.
      WHEN d.kind='armor' THEN
        NOT d.is_set_min OR ps.armor<d.amount
      -- Any ammo: what the player holds of that type against its ceiling.
      WHEN d.kind IN ('bullets','shells','rockets','cells') THEN
        (CASE d.kind WHEN 'bullets' THEN ps.ammo_bullets
                     WHEN 'shells'  THEN ps.ammo_shells
                     WHEN 'rockets' THEN ps.ammo_rockets
                     ELSE ps.ammo_cells END)
        < (SELECT CASE WHEN ps.backpack THEN ad.backpack_cap ELSE ad.cap END
             FROM ammo_defs ad WHERE ad.ammo_type::text = d.kind::text)
      WHEN d.kind='weapon' THEN NOT EXISTS (
        SELECT 1 FROM player_weapon_owned o
        WHERE o.map_id=p.map_id AND o.player_thing_id=p.player_thing_id
          AND o.weapon_id=d.weapon_id
      )
      -- Always taken: Doom's P_TouchSpecialThing has no condition on any of these.
      WHEN d.kind IN ('backpack','key_blue','key_yellow','key_red',
                     'radsuit','invis','lightamp','powermap','invuln') THEN TRUE
      ELSE FALSE
    END
),
ranked AS (
  SELECT e.*,ROW_NUMBER() OVER
    (PARTITION BY e.kind ORDER BY e.dist,e.thing_id) AS rn
  FROM eligible e
),
selected_items AS (
  SELECT DISTINCT thing_id,thing_type FROM ranked WHERE rn=1
)
INSERT INTO pickup_touches
  (map_id,player_thing_id,thing_id,kind,amount,cap,is_set_min,
   weapon_id,armor_class)
SELECT p.map_id,p.player_thing_id,s.thing_id,d.kind,
       -- P_GiveAmmo: "give double ammo in trainer mode, you'll need it in
       -- nightmare" -- sk_baby and sk_nightmare only, not sk_easy.
       CASE WHEN d.kind IN ('bullets','shells','rockets','cells') THEN
         COALESCE(CASE WHEN s.thing_id>=dropped_base THEN d.dropped_amount END,
                  d.amount)*CASE WHEN p.skill_level IN (0,4) THEN 2 ELSE 1 END
         WHEN d.kind='backpack'
           THEN CASE WHEN p.skill_level IN (0,4) THEN 2 ELSE 1 END
         ELSE d.amount END,
       d.cap,d.is_set_min,d.weapon_id,d.armor_class
FROM selected_items s
JOIN pickup_defs d ON d.thing_type=s.thing_type
CROSS JOIN params p;

-- health, armor class, backpack, and keys
WITH staged AS (
  SELECT
    MAX(CASE WHEN kind='health' AND is_set_min THEN amount END) AS health_min,
    SUM(CASE WHEN kind='health' AND NOT is_set_min THEN amount END) AS health_add,
    MIN(CASE WHEN kind='health' AND NOT is_set_min THEN cap END) AS health_cap,
    MAX(CASE WHEN kind='armor' AND is_set_min THEN amount END) AS armor_set,
    SUM(CASE WHEN kind='armor' AND NOT is_set_min THEN amount END) AS armor_add,
    MIN(CASE WHEN kind='armor' AND NOT is_set_min THEN cap END) AS armor_cap,
    MAX(CASE WHEN kind='armor' AND is_set_min THEN armor_class END) AS set_class,
    BOOL_OR(kind='armor' AND NOT is_set_min) AS got_armor_bonus,
    BOOL_OR(kind='backpack') AS got_backpack,
    BOOL_OR(kind='key_blue') AS got_blue,
    BOOL_OR(kind='key_yellow') AS got_yellow,
    BOOL_OR(kind='key_red') AS got_red,
    -- Powerups restart at 60 s instead of stacking.
    MAX(CASE WHEN kind='radsuit' THEN amount END) AS got_radsuit,
    MAX(CASE WHEN kind='invis' THEN amount END) AS got_invis,
    MAX(CASE WHEN kind='lightamp' THEN amount END) AS got_lightamp,
    MAX(CASE WHEN kind='powermap' THEN amount END) AS got_powermap,
    MAX(CASE WHEN kind='invuln' THEN amount END) AS got_invuln,
    count(*) AS taken,
    -- MIN so the line is stable when a tic takes two things at once.
    MIN(pm.message) AS message
  FROM pickup_touches pt
  LEFT JOIN pickup_messages pm ON pm.thing_type = (
    SELECT t.type FROM things t
    WHERE t.map_id=pt.map_id AND t.id=pt.thing_id)
  WHERE pt.map_id=p_map_id AND pt.player_thing_id=p_player_thing_id
)
UPDATE player_state ps
SET
    -- P_TouchSpecialThing ends with player->bonuscount += BONUSADD (6) for
    -- every item taken, which is the gold blink in the renderer. The
    -- summary row exists only when something was actually picked up, so this
    -- fires exactly once per pickup tic.
    bonus_count=LEAST(100,ps.bonus_count+bonus_add*s.taken),
    health=CASE
      WHEN s.health_min IS NOT NULL THEN GREATEST(ps.health,s.health_min)
      WHEN s.health_add IS NOT NULL THEN LEAST(s.health_cap,ps.health+s.health_add)
      ELSE ps.health END,
    armor=CASE
      WHEN s.armor_set IS NOT NULL THEN s.armor_set
      WHEN s.armor_add IS NOT NULL THEN LEAST(s.armor_cap,ps.armor+s.armor_add)
      ELSE ps.armor END,
    armor_class=CASE
      WHEN s.set_class IS NOT NULL THEN s.set_class
      WHEN s.got_armor_bonus AND ps.armor_class=0 THEN 1
      ELSE ps.armor_class END,
    backpack=ps.backpack OR COALESCE(s.got_backpack,FALSE),
    key_blue=ps.key_blue OR COALESCE(s.got_blue,FALSE),
    key_yellow=ps.key_yellow OR COALESCE(s.got_yellow,FALSE),
    key_red=ps.key_red OR COALESCE(s.got_red,FALSE),
    radsuit_tics=GREATEST(ps.radsuit_tics,COALESCE(s.got_radsuit,0)),
    invis_tics=GREATEST(ps.invis_tics,COALESCE(s.got_invis,0)),
    light_amp_tics=GREATEST(ps.light_amp_tics,COALESCE(s.got_lightamp,0)),
    power_map=ps.power_map OR COALESCE(s.got_powermap,0)>0,
    invuln_tics=GREATEST(ps.invuln_tics,COALESCE(s.got_invuln,0)),
    message=COALESCE(s.message, ps.message),
    message_tics=CASE WHEN s.message IS NOT NULL THEN msg_tics
                      ELSE ps.message_tics END
FROM staged s
WHERE ps.map_id=p_map_id AND ps.player_thing_id=p_player_thing_id;

WITH gained AS (
  SELECT ad.ammo_type,
         SUM(CASE WHEN pt.kind::text = ad.ammo_type::text THEN pt.amount
                  WHEN pt.kind = 'backpack' THEN ad.backpack_gives * pt.amount
             END)::int AS amount,
         CASE WHEN ps.backpack THEN ad.backpack_cap ELSE ad.cap END AS cap
  FROM ammo_defs ad
  JOIN player_state ps ON ps.map_id=p_map_id AND ps.player_thing_id=p_player_thing_id
  LEFT JOIN pickup_touches pt
    ON pt.map_id=ps.map_id AND pt.player_thing_id=ps.player_thing_id
  GROUP BY ad.ammo_type, ad.cap, ad.backpack_cap, ps.backpack
)
UPDATE player_state ps
SET ammo_bullets=COALESCE((SELECT LEAST(g.cap,ps.ammo_bullets+g.amount)
                           FROM gained g WHERE g.ammo_type='bullets' AND g.amount IS NOT NULL),ps.ammo_bullets),
    ammo_shells =COALESCE((SELECT LEAST(g.cap,ps.ammo_shells+g.amount)
                           FROM gained g WHERE g.ammo_type='shells' AND g.amount IS NOT NULL),ps.ammo_shells),
    ammo_rockets=COALESCE((SELECT LEAST(g.cap,ps.ammo_rockets+g.amount)
                           FROM gained g WHERE g.ammo_type='rockets' AND g.amount IS NOT NULL),ps.ammo_rockets),
    ammo_cells  =COALESCE((SELECT LEAST(g.cap,ps.ammo_cells+g.amount)
                           FROM gained g WHERE g.ammo_type='cells' AND g.amount IS NOT NULL),ps.ammo_cells)
WHERE ps.map_id=p_map_id AND ps.player_thing_id=p_player_thing_id;

-- consume exactly the staged Things
INSERT INTO picked_up_items (map_id,thing_id)
SELECT DISTINCT map_id,thing_id FROM pickup_touches
WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id
ON CONFLICT (map_id,thing_id) DO NOTHING;

-- stage newly acquired weapon
INSERT INTO pickup_grants (map_id,player_thing_id,weapon_id)
SELECT DISTINCT pt.map_id,pt.player_thing_id,pt.weapon_id
FROM pickup_touches pt
WHERE pt.map_id=p_map_id AND pt.player_thing_id=p_player_thing_id AND pt.kind='weapon'
  AND NOT EXISTS (
    SELECT 1 FROM player_weapon_owned o
    WHERE o.map_id=pt.map_id AND o.player_thing_id=pt.player_thing_id
      AND o.weapon_id=pt.weapon_id
  )
ON CONFLICT (map_id,player_thing_id,weapon_id) DO NOTHING;

-- apply weapon ownership
INSERT INTO player_weapon_owned (map_id,player_thing_id,weapon_id)
SELECT map_id,player_thing_id,weapon_id FROM pickup_grants
WHERE map_id=p_map_id AND player_thing_id=p_player_thing_id
ON CONFLICT (map_id,player_thing_id,weapon_id) DO NOTHING;
$doom$;
