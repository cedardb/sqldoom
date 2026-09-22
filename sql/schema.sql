CREATE TYPE weapon_state AS ENUM ('up', 'down', 'ready', 'fire', 'flash');
CREATE TYPE actor_state AS ENUM ('stand', 'see', 'missile', 'pain', 'die', 'xdeath', 'dead');
CREATE TYPE projectile_state AS ENUM ('fly', 'explode');
CREATE TYPE match_state AS ENUM ('playing', 'intermission');
CREATE TYPE movement_mode AS ENUM ('idle', 'turn', 'full');
CREATE TYPE plane_kind AS ENUM ('floor', 'ceiling');
CREATE TYPE trigger_kind AS ENUM ('use', 'cross', 'shoot');
CREATE TYPE texture_part AS ENUM ('upper', 'middle', 'lower');
CREATE TYPE effect_kind AS ENUM ('puff', 'blood', 'tfog', 'ifog', 'bfg_spray');
CREATE TYPE projectile_kind AS ENUM ('rocket', 'plasma', 'bfg', 'imp_fireball', 'caco_fireball', 'baron_fireball');
CREATE TYPE damage_kind AS ENUM ('direct', 'splash', 'bfg_spray');
CREATE TYPE hit_kind AS ENUM ('wall', 'target');
CREATE TYPE pickup_kind AS ENUM ('health', 'armor', 'bullets', 'shells', 'cells', 'rockets', 'backpack', 'weapon', 'key_red', 'key_blue', 'key_yellow', 'invuln', 'invis', 'radsuit', 'powermap', 'lightamp');
CREATE TYPE screen_kind AS ENUM ('title', 'main', 'episode', 'skill', 'load', 'save', 'help1', 'help2', 'game', 'intermission', 'finale');
CREATE TYPE boss_action AS ENUM ('none', 'exit_level', 'lower_666');
CREATE TYPE special_mechanic AS ENUM ('door', 'floor', 'raise', 'platform', 'ceiling', 'crusher', 'stop', 'lights', 'stairs', 'teleport', 'donut');
CREATE TYPE key_color AS ENUM ('red', 'blue', 'yellow');
CREATE TYPE door_target AS ENUM ('back', 'tag');
CREATE TYPE height_target AS ENUM ('floor', 'floor8', 'highest', 'highest8', 'highest_ceiling', 'lowest', 'lowest_ceiling', 'lowest_ceiling_minus8', 'next_floor', 'plus24', 'plus32', 'plus512', 'shortest_texture');
CREATE TYPE mover_kind AS ENUM ('door_open', 'door_close', 'door_raise', 'door_close_open', 'door_manual_raise', 'floor_raise', 'floor_lower', 'ceiling_raise', 'ceiling_lower', 'platform', 'platform_perpetual', 'crusher', 'donut_raise');
CREATE TYPE light_source AS ENUM ('max_neighbor', 'min_neighbor', 'strobe');
CREATE TYPE sound_cue AS ENUM ('sight', 'active', 'pain', 'death', 'xdeath');
CREATE TYPE ammo_kind AS ENUM ('bullets', 'shells', 'cells', 'rockets');
CREATE TYPE bsp_child AS ENUM ('NODE', 'SSECTOR');

CREATE TABLE IF NOT EXISTS wads (
  wad_id        SERIAL PRIMARY KEY,
  wad_type      TEXT,
  wad_path      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS maps (
  map_id        SERIAL PRIMARY KEY,
  wad_id        INT REFERENCES wads(wad_id),
  name          TEXT NOT NULL, -- e.g., "E1M1",
  sky_texture   TEXT
);

-- Core geometry
CREATE TABLE IF NOT EXISTS vertexes (
  id            INT NOT NULL, -- original index in lump
  map_id        INT REFERENCES maps(map_id),
  x             SMALLINT NOT NULL,
  y             SMALLINT NOT NULL,
  PRIMARY KEY (map_id, id)
);

CREATE TABLE IF NOT EXISTS sectors (
  id            INT NOT NULL,
  map_id        INT REFERENCES maps(map_id),
  floor_height  SMALLINT NOT NULL,
  ceil_height   SMALLINT NOT NULL,
  spawn_floor_height SMALLINT NOT NULL,
  spawn_ceil_height  SMALLINT NOT NULL,
  spawn_floor_tex VARCHAR(8) NOT NULL,
  spawn_light_level SMALLINT NOT NULL,
  floor_tex     VARCHAR(8) NOT NULL,
  ceil_tex      VARCHAR(8) NOT NULL,
  light_level   SMALLINT NOT NULL,
  special       INT NOT NULL,
  tag           INT NOT NULL,
  PRIMARY KEY (map_id, id)
);

CREATE TABLE IF NOT EXISTS sidedefs (
  id            INT NOT NULL,
  map_id        INT REFERENCES maps(map_id),
  x_offset      SMALLINT NOT NULL,
  y_offset      SMALLINT NOT NULL,
  upper_tex     VARCHAR(8) NOT NULL,
  lower_tex     VARCHAR(8) NOT NULL,
  mid_tex       VARCHAR(8) NOT NULL,
  sector_id     INT NOT NULL,
  FOREIGN KEY (map_id, sector_id) REFERENCES sectors (map_id, id),
  PRIMARY KEY (map_id, id)
);

CREATE TABLE IF NOT EXISTS linedefs (
  id            INT NOT NULL,
  map_id        INT REFERENCES maps(map_id),
  v1_id         INT NOT NULL,
  v2_id         INT NOT NULL,
  flags         INT NOT NULL,
  special       INT NOT NULL,
  tag           INT NOT NULL,
  right_sd_id   INT NOT NULL, -- references sidedefs(id) (>=0) or -1
  left_sd_id    INT NOT NULL, -- references sidedefs(id) (>=0) or -1
  cross_activated  BOOLEAN NOT NULL DEFAULT FALSE,
  cross_once       BOOLEAN NOT NULL DEFAULT FALSE,
  monster_crossable BOOLEAN NOT NULL DEFAULT FALSE,
  scrolls          BOOLEAN NOT NULL DEFAULT FALSE,
  -- right_sd_id/left_sd_id take -1 for a missing side, which the renderer
  -- tests for, so those two carry no reference.
  FOREIGN KEY (map_id, v1_id) REFERENCES vertexes (map_id, id),
  FOREIGN KEY (map_id, v2_id) REFERENCES vertexes (map_id, id),
  PRIMARY KEY (map_id, id)
);

-- Gameplay entities
CREATE TABLE IF NOT EXISTS things (
  id            INT NOT NULL,
  map_id        INT REFERENCES maps(map_id),
  x             REAL NOT NULL,
  y             REAL NOT NULL,
  z             REAL NOT NULL DEFAULT 41, -- eye height above floor (SQL spawn/movement)
  angle         REAL NOT NULL,
  spawn_x       SMALLINT NOT NULL,
  spawn_y       SMALLINT NOT NULL,
  spawn_angle   SMALLINT NOT NULL,
  mom_x         REAL NOT NULL DEFAULT 0,  -- momentum
  mom_y         REAL NOT NULL DEFAULT 0,
  type          INT NOT NULL,
  flags         INT NOT NULL,
  PRIMARY KEY (map_id, id)
);

CREATE TABLE IF NOT EXISTS segs (
  id            INT NOT NULL,
  map_id        INT REFERENCES maps(map_id),
  v1_id         INT NOT NULL,
  v2_id         INT NOT NULL,
  angle         SMALLINT NOT NULL,
  linedef_id    INT NOT NULL,
  direction     SMALLINT NOT NULL, -- 0=normal, 1=reversed
  offs          SMALLINT NOT NULL,
  FOREIGN KEY (map_id, v1_id) REFERENCES vertexes (map_id, id),
  FOREIGN KEY (map_id, v2_id) REFERENCES vertexes (map_id, id),
  FOREIGN KEY (map_id, linedef_id) REFERENCES linedefs (map_id, id),
  PRIMARY KEY (map_id, id)
);

-- Immutable sector centroids used for positional mover audio. Materialized with render_segs
CREATE TABLE IF NOT EXISTS sector_sound_origins (
  map_id    INT NOT NULL,
  sector_id INT NOT NULL,
  x         REAL NOT NULL,
  y         REAL NOT NULL,
  PRIMARY KEY (map_id, sector_id)
);

CREATE TABLE IF NOT EXISTS ssectors (
  id            INT NOT NULL,
  map_id        INT REFERENCES maps(map_id),
  seg_count     SMALLINT NOT NULL,
  first_seg_id  SMALLINT NOT NULL,
  FOREIGN KEY (map_id, first_seg_id) REFERENCES segs (map_id, id),
  PRIMARY KEY (map_id, id)
);

CREATE TABLE IF NOT EXISTS nodes (
  id   INT NOT NULL,
  map_id INT REFERENCES maps(map_id),
  x  SMALLINT, -- partition line origin
  y  SMALLINT,
  dx SMALLINT, -- partition line direction
  dy SMALLINT,
  PRIMARY KEY (map_id, id)
);

-- Child rows: one per side ('R'ight / 'L'eft)
CREATE TABLE IF NOT EXISTS node_children (
  map_id  INT NOT NULL,
  node_id INT NOT NULL,
  side    CHAR(1) NOT NULL,
  child_kind bsp_child NOT NULL,
  child_node_id    INT,
  child_ssector_id INT,
  bbox_top SMALLINT,
  bbox_bottom SMALLINT,
  bbox_left SMALLINT,
  bbox_right SMALLINT,
  PRIMARY KEY (map_id, node_id, side)
);

-- Materialized at import.
-- Which sectors touch which, as an edge list, both ways round.
CREATE MATERIALIZED VIEW IF NOT EXISTS sector_adjacency AS
SELECT ld.map_id, ld.id AS linedef_id, r.sector_id, l.sector_id AS other_id
FROM linedefs ld
JOIN sidedefs r ON r.map_id = ld.map_id AND r.id = ld.right_sd_id
JOIN sidedefs l ON l.map_id = ld.map_id AND l.id = ld.left_sd_id
UNION ALL
SELECT ld.map_id, ld.id, l.sector_id, r.sector_id
FROM linedefs ld
JOIN sidedefs r ON r.map_id = ld.map_id AND r.id = ld.right_sd_id
JOIN sidedefs l ON l.map_id = ld.map_id AND l.id = ld.left_sd_id
WITH NO DATA;


CREATE INDEX IF NOT EXISTS idx_sector_adjacency
  ON sector_adjacency (map_id, sector_id);

-- Materialized at import.
-- Linedef -> vertexes -> sidedefs -> sector ids, flattened once.
CREATE MATERIALIZED VIEW IF NOT EXISTS linedef_geom AS
SELECT ld.map_id, ld.id AS linedef_id, v1.x AS x1, v1.y AS y1,
       v2.x AS x2, v2.y AS y2, ld.flags, ld.special,
       ld.right_sd_id, ld.left_sd_id,
       -- fsec/bsec are LEFT JOIN results: NULL when the line is one-sided.
       rs.sector_id AS fsec, ls.sector_id AS bsec
FROM linedefs ld
JOIN vertexes v1 ON v1.map_id=ld.map_id AND v1.id=ld.v1_id
JOIN vertexes v2 ON v2.map_id=ld.map_id AND v2.id=ld.v2_id
LEFT JOIN sidedefs rs ON rs.map_id=ld.map_id AND rs.id=ld.right_sd_id
LEFT JOIN sidedefs ls ON ls.map_id=ld.map_id AND ls.id=ld.left_sd_id
WITH NO DATA;


-- Every subsector's path from the BSP root: one row per ancestor node, with
-- the side taken to reach the subsector. Static per map, materialized at
-- import.
-- Every subsector's path from the BSP root, one row per ancestor node.
CREATE MATERIALIZED VIEW IF NOT EXISTS node_path_steps AS
WITH RECURSIVE walk AS (
  SELECT nc.map_id, nc.child_kind, nc.child_node_id, nc.child_ssector_id,
         1 AS depth, ARRAY[nc.node_id] AS nodes, ARRAY[nc.side::text] AS sides
  FROM node_children nc
  -- The root is the highest-numbered node, as in the WAD.
  JOIN (SELECT map_id, MAX(id) AS root FROM nodes GROUP BY map_id) r
    ON r.map_id=nc.map_id AND r.root=nc.node_id
  UNION ALL
  SELECT nc.map_id, nc.child_kind, nc.child_node_id, nc.child_ssector_id,
         w.depth+1, w.nodes || nc.node_id, w.sides || nc.side::text
  FROM walk w
  JOIN node_children nc ON nc.map_id=w.map_id AND nc.node_id=w.child_node_id
  WHERE w.child_kind='NODE'
)
SELECT w.map_id, w.child_ssector_id AS ssector_id, g.d AS depth,
       w.nodes[g.d] AS node_id, w.sides[g.d]::char(1) AS side
FROM walk w
CROSS JOIN LATERAL generate_series(1, w.depth) AS g(d)
WHERE w.child_kind='SSECTOR'
WITH NO DATA;


-- Large binary lumps the WAD defines. We don't use them but we're a database so let's just keep them
CREATE TABLE IF NOT EXISTS reject_lumps (
  map_id   INT PRIMARY KEY REFERENCES maps(map_id),
  data     BYTEA
);

CREATE TABLE IF NOT EXISTS blockmaps (
  map_id   INT PRIMARY KEY REFERENCES maps(map_id),
  origin_x SMALLINT NOT NULL,
  origin_y SMALLINT NOT NULL,
  cols     SMALLINT NOT NULL,
  rows     SMALLINT NOT NULL,
  payload  BYTEA NOT NULL -- entire table of offsets+lists, for advanced uses
);

-- Immutable renderer-facing seg data. Populated once during loading
CREATE TABLE IF NOT EXISTS render_segs (
  map_id       INT NOT NULL,
  seg_id       INT NOT NULL,
  ssector_id   INT,
  direction    SMALLINT,
  linedef_id   INT,
  x1           SMALLINT,
  y1           SMALLINT,
  x2           SMALLINT,
  y2           SMALLINT,
  seg_u1       DOUBLE PRECISION,
  seg_u2       DOUBLE PRECISION,
  fsec         INT,
  bsec         INT,
  x_offset     SMALLINT,
  y_offset     SMALLINT,
  upper_tex    VARCHAR(8),
  mid_tex      VARCHAR(8),
  lower_tex    VARCHAR(8),
  flags        INT,
  f_floor      SMALLINT,
  f_ceil       SMALLINT,
  f_ceil_tex   VARCHAR(8),
  f_light      SMALLINT,
  b_floor      SMALLINT,
  b_ceil       SMALLINT,
  b_ceil_tex   VARCHAR(8),
  b_light      SMALLINT,
  light_bias   SMALLINT,
  PRIMARY KEY (map_id, seg_id)
);

-- Immutable per-map BSP placement. Coordinates and angles remain on Things,
-- allowing later actor movement without duplicating entity state.
CREATE TABLE IF NOT EXISTS render_things (
  map_id       INT NOT NULL,
  thing_id     INT NOT NULL,
  sector_id    INT NOT NULL,
  spawn_sector_id INT,
  sprite       VARCHAR(4) NOT NULL,
  frame        CHAR(1) NOT NULL,
  fullbright   BOOLEAN NOT NULL,
  spawn_ceiling BOOLEAN NOT NULL,
  thing_height SMALLINT NOT NULL,
  PRIMARY KEY (map_id, thing_id)
);
CREATE INDEX IF NOT EXISTS idx_render_things_map ON render_things (map_id);

-- Doom's COLORMAP lump maps an original PLAYPAL index to a shaded palette
-- index. RGB is stored too so the renderer needs only one compact lookup.
CREATE TABLE IF NOT EXISTS colormap_rgb (
  pal            SMALLINT NOT NULL DEFAULT 0,
  level          SMALLINT,
  palette_index  SMALLINT,
  mapped_index   SMALLINT NOT NULL,
  r              SMALLINT NOT NULL,
  g              SMALLINT NOT NULL,
  b              SMALLINT NOT NULL,
  rgb            BYTEA NOT NULL,
  PRIMARY KEY (pal, level, palette_index)
);

-- Wall textures are composited from patches per TEXTURE1/TEXTURE2; their
-- dimensions vary, so walltex_meta stores width/height for UV wrapping plus
-- one row-major palette-index byte per texel.
CREATE TABLE IF NOT EXISTS walltex_meta (
  name   TEXT PRIMARY KEY,
  width  INT NOT NULL,
  height INT NOT NULL,
  palette_indices BYTEA NOT NULL
);

-- Flats are always packed 64x64 row-major palette-index bitmaps.
CREATE TABLE IF NOT EXISTS flat_textures (
  name TEXT PRIMARY KEY,
  palette_indices BYTEA NOT NULL
);

CREATE TABLE IF NOT EXISTS sprite_frames (
  sprite      VARCHAR(4) NOT NULL,
  frame       CHAR(1) NOT NULL,
  rotation    SMALLINT NOT NULL,
  lump_name   VARCHAR(8) NOT NULL,
  flipped     BOOLEAN NOT NULL,
  width       SMALLINT NOT NULL,
  height      SMALLINT NOT NULL,
  left_offset SMALLINT NOT NULL,
  top_offset  SMALLINT NOT NULL,
  PRIMARY KEY (sprite, frame, rotation)
);

CREATE TABLE IF NOT EXISTS sprite_lumps (
  lump_name VARCHAR(8) PRIMARY KEY,
  pixels    BYTEA NOT NULL,
  mask      BYTEA NOT NULL
);

-- The status-bar patches (STBAR background, STTNUM digit font, STFST
-- mugshot states, ...)
CREATE TABLE IF NOT EXISTS ui_patches (
  name        VARCHAR(8) PRIMARY KEY,
  width       SMALLINT NOT NULL,
  height      SMALLINT NOT NULL,
  left_offset SMALLINT NOT NULL,
  top_offset  SMALLINT NOT NULL,
  pixels      BYTEA NOT NULL,
  mask        BYTEA NOT NULL
);

-- Opaque UI texels expanded once at WAD load time.
CREATE TABLE IF NOT EXISTS ui_patch_pixels (
  name          VARCHAR(8) NOT NULL,
  dx            SMALLINT NOT NULL,
  dy            SMALLINT NOT NULL,
  palette_index SMALLINT NOT NULL,
  PRIMARY KEY (name, dx, dy)
);

-- The status bar's own patches, split out of ui_patch_pixels so the renderer
-- does not scan the menu art 35 times a second.
CREATE MATERIALIZED VIEW IF NOT EXISTS ui_hud_pixels AS
SELECT name, dx, dy, palette_index
FROM ui_patch_pixels WHERE name LIKE 'ST%'
WITH NO DATA;

CREATE MATERIALIZED VIEW IF NOT EXISTS ui_static_pixels AS
WITH static_layers(name,layer,x,y) AS (
  VALUES ('STBAR'::text,0,0,168),
         ('STTPRCNT'::text,1,90,172),
         ('STTPRCNT'::text,1,221,172),
         ('STARMS'::text,1,104,168)
), candidates AS (
  SELECT l.layer,
         l.x-p.left_offset+px.dx AS x,
         l.y-p.top_offset+px.dy AS y,
         px.palette_index,
         ROW_NUMBER() OVER (
           PARTITION BY l.x-p.left_offset+px.dx,
                        l.y-p.top_offset+px.dy
           ORDER BY l.layer DESC,l.name
         ) AS rn
  FROM static_layers l
  JOIN ui_patches p ON p.name=l.name
  JOIN ui_patch_pixels px ON px.name=l.name
)
SELECT c.x, c.y, cm.rgb, c.palette_index
FROM candidates c
JOIN colormap_rgb cm
  ON cm.pal=0 AND cm.level=0 AND cm.palette_index=c.palette_index
WHERE c.rn=1
WITH NO DATA;

-- Doom's DMX-format DS* lumps, wrapped as standard mono WAV files by the WAD loader.
CREATE TABLE IF NOT EXISTS sound_assets (
  name     VARCHAR(8) PRIMARY KEY,
  wav_data BYTEA NOT NULL
);

-- Original MUS bytes are retained alongside a loader-materialized standard
-- MIDI stream.
CREATE TABLE IF NOT EXISTS music_assets (
  name         VARCHAR(8) PRIMARY KEY,
  mus_data     BYTEA NOT NULL,
  midi_data    BYTEA NOT NULL,
  audio_data   BYTEA,
  audio_format TEXT
);

CREATE TABLE IF NOT EXISTS map_music (
  map_id     INT PRIMARY KEY,
  music_name VARCHAR(8) NOT NULL
);

-- Static spawn-state metadata derived from id Software's mobjinfo/state tables.
CREATE TABLE IF NOT EXISTS thing_sprite_defs (
  thing_type    INT PRIMARY KEY,
  sprite        VARCHAR(4) NOT NULL,
  frame         CHAR(1) NOT NULL,
  fullbright    BOOLEAN NOT NULL,
  spawn_ceiling BOOLEAN NOT NULL,
  thing_height  SMALLINT NOT NULL
);

CREATE TABLE IF NOT EXISTS pickup_messages (
  thing_type INT PRIMARY KEY,
  message    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chase_dir_defs (
  dir         SMALLINT PRIMARY KEY,
  name        TEXT NOT NULL,
  dx          DOUBLE PRECISION NOT NULL,
  dy          DOUBLE PRECISION NOT NULL,
  angle       REAL NOT NULL,
  opposite    SMALLINT NOT NULL,
  is_diagonal BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS thing_role_defs (
  thing_type          INT PRIMARY KEY,
  name                TEXT NOT NULL,
  is_player_start     BOOLEAN NOT NULL DEFAULT FALSE,
  player_number       SMALLINT,
  is_deathmatch_start BOOLEAN NOT NULL DEFAULT FALSE,
  is_teleport_dest    BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS thing_blocking_defs (
  thing_type INT PRIMARY KEY,
  radius     REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS projectile_defs (
  projectile_type projectile_kind PRIMARY KEY,
  name            TEXT NOT NULL,
  radius          REAL NOT NULL,
  speed           REAL,
  dmg_dice_mult   INT,
  dmg_random_id   SMALLINT,
  explode_tics    SMALLINT NOT NULL,
  fly_timeout     SMALLINT NOT NULL,
  blast_radius    REAL,
  spray_at_tic    SMALLINT,
  spray_rays        SMALLINT,
  spray_arc_degrees REAL,
  spray_range       REAL,
  spray_dice        SMALLINT,
  spray_random_base SMALLINT,
  fly_sprite        VARCHAR(4),
  impact_sprite     VARCHAR(4),
  dmg_dice_count    SMALLINT NOT NULL DEFAULT 8
);

CREATE TABLE IF NOT EXISTS thing_combat_defs (
  thing_type       INT PRIMARY KEY,
  spawn_health     INT NOT NULL,
  radius           REAL NOT NULL,
  death_sprite     VARCHAR(4) NOT NULL,
  death_frame      CHAR(1) NOT NULL,
  death_fullbright BOOLEAN NOT NULL,
  no_blood         BOOLEAN NOT NULL DEFAULT FALSE,
  pain_chance      SMALLINT NOT NULL DEFAULT 0,   -- 0..256 threshold compared with Doom's byte-sized P_Random result.
  attack_range    REAL NOT NULL DEFAULT 2048,
  xdeath_frame    CHAR(1),
  mass            INT NOT NULL DEFAULT 100,
  counts_kill      BOOLEAN NOT NULL DEFAULT FALSE,
  name             TEXT,
  height           SMALLINT NOT NULL DEFAULT 56,
  floats           BOOLEAN NOT NULL DEFAULT FALSE,
  skull_fly        BOOLEAN NOT NULL DEFAULT FALSE,
  missile_type     projectile_kind,
  missile_speed    REAL,
  missile_dice     SMALLINT,
  hitscan_pellets  SMALLINT, -- How many pellets do they fire with one attack?
  melee_mult       SMALLINT,  -- The bite at MELEERANGE: melee_mult * (1..melee_sides); NULL when the thing has no melee attack.
  melee_sides      SMALLINT,
  fast_on_nightmare BOOLEAN NOT NULL DEFAULT FALSE,
  attack_sound     VARCHAR(8),
  explodes         BOOLEAN NOT NULL DEFAULT FALSE,
  drops_thing_type INT,
  blast_radius     REAL,
  hitscan_mult     SMALLINT,
  hitscan_sides    SMALLINT,
  charge_mult      SMALLINT,
  charge_sides     SMALLINT,
  fuzzy            BOOLEAN NOT NULL DEFAULT FALSE,
  FOREIGN KEY (thing_type) REFERENCES thing_sprite_defs (thing_type),
  FOREIGN KEY (missile_type) REFERENCES projectile_defs (projectile_type),
  FOREIGN KEY (drops_thing_type) REFERENCES thing_sprite_defs (thing_type)
);

CREATE TABLE IF NOT EXISTS weapon_defs (
  weapon_id     INT PRIMARY KEY,
  name          TEXT NOT NULL,
  slot          INT NOT NULL,
  ammo_type     ammo_kind,
  ammo_per_shot INT NOT NULL DEFAULT 0,
  sprite        VARCHAR(4) NOT NULL,
  flash_sprite  VARCHAR(4),
  pellet_count  INT NOT NULL,
  max_range     REAL NOT NULL,
  dmg_dice_count INT NOT NULL,
  dmg_dice_mult  INT NOT NULL,
  projectile_type projectile_kind,
  idle_loop_sound VARCHAR(8),
  FOREIGN KEY (projectile_type) REFERENCES projectile_defs (projectile_type)
);

-- Per-weapon psprite animation
CREATE TABLE IF NOT EXISTS weapon_frames (
  weapon_id       INT NOT NULL,
  state           weapon_state NOT NULL,
  seq_index       INT NOT NULL,
  frame           CHAR(1) NOT NULL,
  tics            INT NOT NULL,
  fullbright      BOOLEAN NOT NULL DEFAULT FALSE,
  is_attack_frame BOOLEAN NOT NULL DEFAULT FALSE,
  refire_check    BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (weapon_id, state, seq_index),
  FOREIGN KEY (weapon_id) REFERENCES weapon_defs (weapon_id)
);

-- Who is waiting for a slot, in order of arrival?
CREATE TABLE IF NOT EXISTS doom_constants (
  name   TEXT PRIMARY KEY,
  value  DOUBLE PRECISION NOT NULL,
  source TEXT NOT NULL
);

-- Hand-authored animation/attack state table
CREATE TABLE IF NOT EXISTS thing_ai_frames (
  thing_type      INT NOT NULL,
  state           actor_state NOT NULL,
  seq_index       INT NOT NULL,
  frame           CHAR(1) NOT NULL,
  tics            INT NOT NULL,
  fullbright      BOOLEAN NOT NULL DEFAULT FALSE,
  is_attack_frame BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (thing_type, state, seq_index),
  FOREIGN KEY (thing_type) REFERENCES thing_sprite_defs (thing_type)
);

-- Health/armor/ammo/weapon pickup effects, keyed by DoomEd thing type


CREATE TABLE IF NOT EXISTS effect_sprite_defs (
  effect_type    effect_kind PRIMARY KEY,
  sprite         VARCHAR(4) NOT NULL,
  frame_sequence TEXT NOT NULL,
  tics_per_frame SMALLINT NOT NULL,
  fullbright     BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS ammo_defs (
  ammo_type      ammo_kind PRIMARY KEY,
  cap            INT NOT NULL,
  backpack_cap   INT NOT NULL,
  backpack_gives INT NOT NULL
);

CREATE TABLE IF NOT EXISTS pickup_defs (
  thing_type  INT NOT NULL,
  kind        pickup_kind NOT NULL,
  amount      INT NOT NULL,
  cap         INT NOT NULL,
  is_set_min  BOOLEAN NOT NULL DEFAULT FALSE,
  weapon_id   INT,
  armor_class SMALLINT,
  -- MF_COUNTITEM: contributes to the intermission's ITEMS denominator.
  counts_item BOOLEAN NOT NULL DEFAULT FALSE,
  -- MF_DROPPED: what a monster's drop gives, where that is less than the
  -- one lying on the floor. NULL when the type is never dropped.
  dropped_amount INT,
  -- Stimpacks and medikits stay put at full health; bonuses, soulspheres and
  -- berserk are taken whatever the player has.
  only_when_below_cap BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (thing_type, kind),
  FOREIGN KEY (thing_type) REFERENCES thing_sprite_defs (thing_type)
);

-- One row per selectable menu line, in Doom's own screen coordinates.
CREATE TABLE IF NOT EXISTS menu_items (
  screen screen_kind NOT NULL,
  idx    INT  NOT NULL,
  -- NULL for a selectable line that draws no patch of its own: the Load and
  -- Save slots are a bevel plus text, and are listed here only so the cursor
  -- has coordinates to sit on.
  patch  TEXT,
  x      INT  NOT NULL,
  y      INT  NOT NULL,
  PRIMARY KEY (screen, idx)
);

-- Non-selectable decoration for a screen (logos, headings).
CREATE TABLE IF NOT EXISTS menu_decor (
  screen screen_kind NOT NULL,
  seq    INT  NOT NULL,
  patch  TEXT NOT NULL,
  x      INT  NOT NULL,
  y      INT  NOT NULL,
  PRIMARY KEY (screen, seq)
);

-- Doom's par times (g_game.c pars[4][10]), one row per level.
CREATE TABLE IF NOT EXISTS level_pars (
  episode  INT NOT NULL,
  level    INT NOT NULL,
  par_secs INT NOT NULL,
  PRIMARY KEY (episode, level)
);

-- On an episode's last map Doom watches for the last monster of one type to
-- die and then runs a level-wide action.
CREATE TABLE IF NOT EXISTS boss_actions (
  map_name  TEXT PRIMARY KEY,
  boss_type INT  NOT NULL,
  action    boss_action NOT NULL
);

-- Doom keeps these strings in the executable rather than in the WAD, so they
-- are seeded here alongside the other static catalogs. flat is the tiled
-- background F_TextWrite erases to; patch is what F_Drawer shows once the
-- text has finished.
CREATE TABLE IF NOT EXISTS finale_defs (
  episode    INT  PRIMARY KEY,
  flat       TEXT NOT NULL,
  patch      TEXT NOT NULL,
  story_text TEXT NOT NULL
);

-- Doom's linedef types are a numbered list of behaviours.
-- Rows are seeded in sql/loader/game_data.sql
CREATE TABLE IF NOT EXISTS line_special_defs (
  special         INT PRIMARY KEY,
  name            TEXT NOT NULL,
  -- Which dispatch branch in doom_cs_activate_specials owns this type.
  -- NULL for the ones that branch has not been converted to read from here
  -- yet; those still carry their own list.
  mechanic        special_mechanic,
  -- How it is triggered.
  cross_activated BOOLEAN NOT NULL DEFAULT FALSE,
  cross_once      BOOLEAN NOT NULL DEFAULT FALSE,
  monster_crossable BOOLEAN NOT NULL DEFAULT FALSE,
  use_activated   BOOLEAN NOT NULL DEFAULT FALSE,
  use_once        BOOLEAN NOT NULL DEFAULT FALSE,
  key_required    key_color,
  is_exit         BOOLEAN NOT NULL DEFAULT FALSE,
  secret_exit     BOOLEAN NOT NULL DEFAULT FALSE,
  door_target     door_target,
  height_target   height_target,
  change_tex      BOOLEAN NOT NULL DEFAULT FALSE,
  flips_switch    BOOLEAN NOT NULL DEFAULT FALSE,
  shoot_activated BOOLEAN NOT NULL DEFAULT FALSE,
  monster_usable  BOOLEAN NOT NULL DEFAULT FALSE,
  scrolls         BOOLEAN NOT NULL DEFAULT FALSE,
  target_light    SMALLINT,
  mover_type      mover_kind,
  direction       SMALLINT,
  step_height     SMALLINT,
  crush           BOOLEAN NOT NULL DEFAULT FALSE,
  light_source    light_source,
  stops_mover     mover_kind,
  -- Map units per tic. Fractional because vanilla's plats are fixed point:
  -- raiseAndChange runs at PLATSPEED/2 (p_plats.c).
  speed           NUMERIC(4,1),
  wait_tics       INT
);

CREATE TABLE IF NOT EXISTS sector_special_defs (
  special   INT PRIMARY KEY,
  name      TEXT NOT NULL,
  is_secret BOOLEAN NOT NULL DEFAULT FALSE,
  damage_per_hit INT,
  ends_level_at_low_health BOOLEAN NOT NULL DEFAULT FALSE,
  exit_at_health INT
);

CREATE TABLE IF NOT EXISTS thing_sound_defs (
  thing_type INT  NOT NULL,
  -- 'sight' on waking, 'pain' on entering the pain frame, 'death' on dying,
  -- 'active' the occasional idle growl while chasing.
  cue        sound_cue NOT NULL,
  variant    INT  NOT NULL,
  sound_name VARCHAR(8) NOT NULL,
  PRIMARY KEY (thing_type, cue, variant)
);

-- Active/completed sector-plane thinkers. Direction follows Doom's door
-- convention: 1 opening, 0 waiting, -1 closing, 2 finished.
CREATE TABLE IF NOT EXISTS sector_movers (
  map_id         INT NOT NULL,
  sector_id      INT NOT NULL,
  source_line_id INT,
  mover_type     mover_kind NOT NULL,
  plane          plane_kind NOT NULL DEFAULT 'ceiling',
  direction      SMALLINT NOT NULL,
  bottom_height  SMALLINT,
  top_height     SMALLINT NOT NULL,
  speed          NUMERIC(4,1) NOT NULL,
  -- Heights are whole map units, so a speed with a fraction moves nothing on
  -- some tics: what it does not spend this tic is carried to the next, which
  -- is what vanilla gets for free from 16.16 fixed point.
  move_carry     NUMERIC(4,1) NOT NULL DEFAULT 0,
  wait_tics      INT NOT NULL,
  countdown      INT NOT NULL DEFAULT 0,
  next_ceiling   SMALLINT,
  next_floor     SMALLINT,
  target_floor_tex VARCHAR(8),
  moved_this_tick BOOLEAN NOT NULL DEFAULT FALSE,
  crush          BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (map_id, sector_id)
);

CREATE TABLE IF NOT EXISTS line_special_events (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  line_id         INT NOT NULL,
  trigger_type    trigger_kind NOT NULL,
  from_front      BOOLEAN NOT NULL,
  PRIMARY KEY (map_id, player_thing_id, line_id, trigger_type)
);

CREATE TABLE IF NOT EXISTS line_use_results (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  line_id         INT,
  special         INT,
  locked          BOOLEAN NOT NULL DEFAULT FALSE,
  eligible        BOOLEAN NOT NULL DEFAULT FALSE,
  from_front      BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (map_id, player_thing_id)
);

-- Existence marks a W1/S1/D1 line as already consumed this playthrough.
CREATE TABLE IF NOT EXISTS line_activations (
  map_id  INT NOT NULL,
  line_id INT NOT NULL,
  PRIMARY KEY (map_id, line_id)
);

-- Active switch/button texture substitutions. countdown=-1 is a permanent
-- one-shot switch; positive countdowns restore repeatable buttons at zero.
CREATE TABLE IF NOT EXISTS line_buttons (
  map_id          INT NOT NULL,
  line_id         INT NOT NULL,
  sidedef_id      INT NOT NULL,
  texture_part    texture_part NOT NULL,
  original_tex    VARCHAR(8) NOT NULL,
  active_tex      VARCHAR(8) NOT NULL,
  countdown       INT NOT NULL,
  just_restored   BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (map_id, line_id, sidedef_id, texture_part)
);

CREATE TABLE IF NOT EXISTS sound_events (
  event_id        BIGSERIAL PRIMARY KEY,
  map_id          INT NOT NULL,
  event_key       TEXT NOT NULL,
  level_tic       BIGINT NOT NULL,
  sound_name      VARCHAR(8) NOT NULL,
  source_thing_id INT,
  source_x        REAL,
  source_y        REAL,
  UNIQUE (map_id, event_key)
);
CREATE INDEX IF NOT EXISTS idx_sound_events_map_id
  ON sound_events (map_id, event_id);

CREATE TABLE IF NOT EXISTS world_effects (
  map_id     INT NOT NULL,
  effect_id  BIGINT NOT NULL,
  effect_type effect_kind NOT NULL,
  x          REAL NOT NULL,
  y          REAL NOT NULL,
  z          REAL NOT NULL,
  sector_id  INT,
  age        SMALLINT NOT NULL DEFAULT 0,
  PRIMARY KEY (map_id, effect_id)
);
CREATE INDEX IF NOT EXISTS idx_world_effects_map ON world_effects (map_id);

-- Live monster missiles
CREATE TABLE IF NOT EXISTS monster_projectiles (
  map_id          INT NOT NULL,
  projectile_id   BIGINT NOT NULL,
  owner_thing_id  INT NOT NULL,
  projectile_type projectile_kind NOT NULL,
  x               REAL NOT NULL,
  y               REAL NOT NULL,
  z               REAL NOT NULL,
  vx              REAL NOT NULL,
  vy              REAL NOT NULL,
  vz              REAL NOT NULL,
  sector_id       INT,
  state           projectile_state NOT NULL DEFAULT 'fly',
  age             SMALLINT NOT NULL DEFAULT 0,
  damage          SMALLINT NOT NULL,
  impact_player   BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (map_id, projectile_id)
);
CREATE INDEX IF NOT EXISTS idx_monster_projectiles_map
  ON monster_projectiles (map_id);

CREATE TABLE IF NOT EXISTS projectile_impacts (
  map_id          INT NOT NULL,
  projectile_id   BIGINT NOT NULL,
  projectile_type projectile_kind NOT NULL,
  owner_thing_id  INT NOT NULL,
  x               REAL NOT NULL,
  y               REAL NOT NULL,
  z               REAL NOT NULL,
  target_player   BOOLEAN NOT NULL DEFAULT FALSE,
  target_thing_id INT,
  target_player_thing_id INT,
  PRIMARY KEY (map_id, projectile_id)
);

CREATE TABLE IF NOT EXISTS projectile_damage (
  map_id        INT NOT NULL,
  projectile_id BIGINT NOT NULL,
  damage_kind  damage_kind NOT NULL,
  hit_index    INT NOT NULL,
  thing_id     INT NOT NULL,
  damage       INT NOT NULL,
  PRIMARY KEY (map_id, projectile_id, damage_kind, hit_index)
);

CREATE TABLE IF NOT EXISTS hitscan_hits (
  map_id INT NOT NULL, player_thing_id INT NOT NULL, shot_serial BIGINT NOT NULL,
  pellet SMALLINT NOT NULL, damage SMALLINT NOT NULL, thing_id INT,
  sector_id INT, no_blood BOOLEAN NOT NULL, distance REAL NOT NULL,
  angle DOUBLE PRECISION NOT NULL, slope DOUBLE PRECISION NOT NULL,
  hit_kind hit_kind NOT NULL, px REAL NOT NULL, py REAL NOT NULL,
  shoot_z REAL NOT NULL,
  line_id INT,
  line_from_front BOOLEAN,
  PRIMARY KEY (map_id, player_thing_id, shot_serial, pellet)
);

-- a taken THING and the tic it returns.
CREATE TABLE IF NOT EXISTS item_respawns (
  map_id      INT NOT NULL,
  thing_id    INT NOT NULL,
  respawn_tic BIGINT NOT NULL,
  PRIMARY KEY (map_id, thing_id)
);

-- Per-sector animated lighting.
CREATE TABLE IF NOT EXISTS sector_light_fx (
  map_id      INT NOT NULL,
  sector_id   INT NOT NULL,
  special     SMALLINT NOT NULL,
  base_light  SMALLINT NOT NULL,
  dark_light  SMALLINT NOT NULL,
  PRIMARY KEY (map_id, sector_id)
);

-- Doom reveals the automap as you go: a line is drawn only once it has been
-- seen (vanilla's ML_MAPPED), and the computer area map reveals the rest.
CREATE TABLE IF NOT EXISTS mapped_lines (
  map_id  INT NOT NULL,
  line_id INT NOT NULL,
  PRIMARY KEY (map_id, line_id)
);

-- Per-player weapon psprite state machine. state is 'up'/'down'/'ready'/ 'fire'.
CREATE TABLE IF NOT EXISTS player_weapons (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  current_weapon  INT NOT NULL DEFAULT 2,
  pending_weapon  INT,
  state           weapon_state NOT NULL DEFAULT 'up',
  seq_index       INT NOT NULL DEFAULT 0,
  tics            SMALLINT NOT NULL DEFAULT 1,
  flash_seq_index INT,
  flash_tics      SMALLINT NOT NULL DEFAULT 0,
  sx              REAL NOT NULL DEFAULT 1,
  sy              REAL NOT NULL DEFAULT 128,
  shot_serial     BIGINT NOT NULL DEFAULT 0,
  fired_this_tick BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (map_id, player_thing_id)
);

-- Which weapons a player currently owns.
CREATE TABLE IF NOT EXISTS player_weapon_owned (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  weapon_id       INT NOT NULL,
  PRIMARY KEY (map_id, player_thing_id, weapon_id)
);

CREATE TABLE IF NOT EXISTS player_state (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  health          INT NOT NULL DEFAULT 100,
  alive           BOOLEAN NOT NULL DEFAULT TRUE,
  level_tics      BIGINT NOT NULL DEFAULT 0,  -- Authoritative 35 Hz gameplay clock for the current run.
  previous_x      REAL NOT NULL DEFAULT 0,
  previous_y      REAL NOT NULL DEFAULT 0,
  position_x      REAL NOT NULL DEFAULT 0,
  position_y      REAL NOT NULL DEFAULT 0,
  base_z          REAL NOT NULL DEFAULT 41,
  view_z          REAL NOT NULL DEFAULT 41,
  view_angle      REAL NOT NULL DEFAULT 0,
  momentum_x      REAL NOT NULL DEFAULT 0,
  momentum_y      REAL NOT NULL DEFAULT 0,
  bob_strength    REAL NOT NULL DEFAULT 0,
  previous_view_z REAL NOT NULL DEFAULT 41,
  previous_view_angle REAL NOT NULL DEFAULT 0,
  sector_id       INT,
  pain_face_tics  INT NOT NULL DEFAULT 0,
  armor           INT NOT NULL DEFAULT 0,
  armor_class     SMALLINT NOT NULL DEFAULT 0,
  backpack        BOOLEAN NOT NULL DEFAULT FALSE,
  ammo_bullets    INT NOT NULL DEFAULT 0,
  ammo_shells     INT NOT NULL DEFAULT 0,
  ammo_rockets    INT NOT NULL DEFAULT 0,
  ammo_cells      INT NOT NULL DEFAULT 0,
  key_blue        BOOLEAN NOT NULL DEFAULT FALSE,
  key_yellow      BOOLEAN NOT NULL DEFAULT FALSE,
  key_red         BOOLEAN NOT NULL DEFAULT FALSE,
  radsuit_tics     INT NOT NULL DEFAULT 0,
  invis_tics       INT NOT NULL DEFAULT 0,
  momentum_z       REAL NOT NULL DEFAULT 0,
  damage_count     INT NOT NULL DEFAULT 0,
  bonus_count      INT NOT NULL DEFAULT 0,
  light_amp_tics   INT NOT NULL DEFAULT 0,
  power_map        BOOLEAN NOT NULL DEFAULT FALSE,
  god_mode         BOOLEAN NOT NULL DEFAULT FALSE,
  noclip           BOOLEAN NOT NULL DEFAULT FALSE,
  invuln_tics      INT NOT NULL DEFAULT 0,
  berserk          BOOLEAN NOT NULL DEFAULT FALSE,
  message          TEXT,
  message_tics     INT NOT NULL DEFAULT 0,
  frags            INT NOT NULL DEFAULT 0,
  death_tics       INT NOT NULL DEFAULT 0,
  killer_id        INT,
  sprite_frame     CHAR(1) NOT NULL DEFAULT 'A',
  PRIMARY KEY (map_id, player_thing_id)
);

-- The client submits exactly one row of device input for each 35 Hz tic.
-- The row is overwritten on every tic rather than used as a history.
CREATE TABLE IF NOT EXISTS game_tic_commands (
  map_id           INT NOT NULL,
  player_thing_id  INT NOT NULL,
  command_serial   BIGINT NOT NULL DEFAULT 0,
  skill            INT NOT NULL DEFAULT 2,
  skill_bit        INT NOT NULL DEFAULT 2,
  move_fwd         REAL NOT NULL DEFAULT 0,
  move_strafe      REAL NOT NULL DEFAULT 0,
  running          BOOLEAN NOT NULL DEFAULT FALSE,
  turn_degrees     REAL NOT NULL DEFAULT 0,
  attack_held      BOOLEAN NOT NULL DEFAULT FALSE,
  weapon_switch_to INT,
  use_requested    BOOLEAN NOT NULL DEFAULT FALSE,
  -- Filled by the CedarScript movement planner after movers are advanced;
  -- the client dispatches the one prepared movement path selected by SQL.
  movement_mode    movement_mode NOT NULL DEFAULT 'idle',
  PRIMARY KEY (map_id, player_thing_id)
);

-- One SQL-owned snapshot per player's current/completed run.
CREATE TABLE IF NOT EXISTS level_stats (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  skill_bit       INT NOT NULL,
  level_tics      BIGINT NOT NULL DEFAULT 0,
  par_tics        BIGINT,
  kills           INT NOT NULL DEFAULT 0,
  total_kills     INT NOT NULL DEFAULT 0,
  items           INT NOT NULL DEFAULT 0,
  total_items     INT NOT NULL DEFAULT 0,
  secrets         INT NOT NULL DEFAULT 0,
  total_secrets   INT NOT NULL DEFAULT 0,
  completed       BOOLEAN NOT NULL DEFAULT FALSE,
  secret_exit     BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (map_id, player_thing_id)
);

-- Vanilla clears a secret sector's special after its first visit. Keeping the
-- immutable sector data intact and recording that visit here gives the same
-- once-per-sector behavior without modifying map geometry metadata.
CREATE TABLE IF NOT EXISTS level_secret_discoveries (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  sector_id       INT NOT NULL,
  PRIMARY KEY (map_id, player_thing_id, sector_id)
);

-- Per-tic pickup worklist
CREATE TABLE IF NOT EXISTS pickup_touches (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  thing_id        INT NOT NULL,
  kind            pickup_kind NOT NULL,
  amount          INT NOT NULL,
  cap             INT NOT NULL,
  is_set_min      BOOLEAN NOT NULL,
  weapon_id       INT,
  armor_class     SMALLINT,
  PRIMARY KEY (map_id, player_thing_id, thing_id, kind)
);

CREATE TABLE IF NOT EXISTS picked_up_items (
  map_id   INT NOT NULL,
  thing_id INT NOT NULL,
  PRIMARY KEY (map_id, thing_id)
);

-- Ephemeral handoff from pickup detection to ownership
CREATE TABLE IF NOT EXISTS pickup_grants (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  weapon_id       INT NOT NULL,
  PRIMARY KEY (map_id, player_thing_id, weapon_id)
);

CREATE TABLE IF NOT EXISTS tic_trace (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  stages          BIGINT NOT NULL,
  PRIMARY KEY (map_id, player_thing_id)
);

CREATE TABLE IF NOT EXISTS thing_health (
  map_id    INT NOT NULL,
  thing_id  INT NOT NULL,
  health    INT NOT NULL,
  max_health INT NOT NULL,
  alive     BOOLEAN NOT NULL,
  PRIMARY KEY (map_id, thing_id)
);

CREATE TABLE IF NOT EXISTS monster_steps (
  map_id   INT NOT NULL,
  thing_id INT NOT NULL,
  old_x    REAL NOT NULL,
  old_y    REAL NOT NULL,
  new_x    REAL NOT NULL,
  new_y    REAL NOT NULL,
  face_angle REAL NOT NULL,
  movedir  SMALLINT,
  movecount SMALLINT NOT NULL DEFAULT 0,
  PRIMARY KEY (map_id, thing_id)
);

CREATE TABLE IF NOT EXISTS monster_attack_damage (
  map_id        INT NOT NULL,
  attacker_id   INT NOT NULL,
  -- NULL when the attack is aimed at a player rather than another thing.
  victim_id     INT,
  victim_player INT NOT NULL,
  dmg           INT NOT NULL,
  -- The attacker's position
  mx            DOUBLE PRECISION NOT NULL,
  my            DOUBLE PRECISION NOT NULL
);

-- Monsters that stepped onto a teleport line this tic, and where EV_Teleport
-- is sending them.
CREATE TABLE IF NOT EXISTS monster_teleports (
  map_id     INT NOT NULL,
  thing_id   INT NOT NULL,
  dest_x     REAL NOT NULL,
  dest_y     REAL NOT NULL,
  dest_angle REAL NOT NULL,
  sector_id  INT NOT NULL,
  PRIMARY KEY (map_id, thing_id)
);

CREATE TABLE IF NOT EXISTS monster_deaths (
  map_id    INT NOT NULL,
  thing_id  INT NOT NULL,
  death_tic BIGINT NOT NULL,
  PRIMARY KEY (map_id, thing_id)
);

-- This tic's chosen respawns
CREATE TABLE IF NOT EXISTS monster_respawns (
  map_id   INT NOT NULL,
  thing_id INT NOT NULL,
  old_x    REAL NOT NULL,
  old_y    REAL NOT NULL,
  PRIMARY KEY (map_id, thing_id)
);

-- Per-monster runtime AI state. state_tics counts down to the next frame;
-- reaching 0 advances seq_index within thing_ai_frames for (type, state),
-- or transitions to a new state in the CedarScript monster tick. sector_id tracks
-- the monster's live position for rendering/light once it starts moving
CREATE TABLE IF NOT EXISTS monster_ai (
  map_id          INT NOT NULL,
  thing_id        INT NOT NULL,
  state           actor_state NOT NULL DEFAULT 'stand',
  state_tics      INT NOT NULL DEFAULT -1,
  seq_index       INT NOT NULL DEFAULT 0,
  sector_id       INT,
  attack_cooldown INT NOT NULL DEFAULT 0,
  fired_this_tick BOOLEAN NOT NULL DEFAULT FALSE,
  target_thing_id  INT,
  PRIMARY KEY (map_id, thing_id),
  charge_tics     INT NOT NULL DEFAULT 0,
  movedir         SMALLINT DEFAULT 0,
  movecount       SMALLINT NOT NULL DEFAULT 0
);

-- Where each player is looking on the automap
CREATE TABLE IF NOT EXISTS automap_view (
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  center_x        REAL NOT NULL DEFAULT 0,
  center_y        REAL NOT NULL DEFAULT 0,
  zoom            REAL NOT NULL DEFAULT 1.0,
  follow          BOOLEAN NOT NULL DEFAULT TRUE,
  grid            BOOLEAN NOT NULL DEFAULT FALSE,
  -- IDDT's counter: 0 off, 1 all lines, 2 also all things.
  cheat           SMALLINT NOT NULL DEFAULT 0,
  PRIMARY KEY (map_id, player_thing_id)
);

CREATE TABLE IF NOT EXISTS demos (
  demo_id     INT PRIMARY KEY,
  name        TEXT NOT NULL,
  map_id      INT NOT NULL,
  player_thing_id INT NOT NULL,
  skill       INT NOT NULL,
  tic_count   INT NOT NULL DEFAULT 0,
  recorded_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS demo_tics (
  demo_id          INT NOT NULL,
  tic              INT NOT NULL,
  move_fwd         REAL NOT NULL,
  move_strafe      REAL NOT NULL,
  running          BOOLEAN NOT NULL,
  turn_degrees     REAL NOT NULL,
  attack_held      BOOLEAN NOT NULL,
  weapon_switch_to INT,
  use_requested    BOOLEAN NOT NULL,
  PRIMARY KEY (demo_id, tic)
);

CREATE TABLE IF NOT EXISTS screen_state (
  id            INT PRIMARY KEY,
  screen        screen_kind NOT NULL,
  cursor_index  INT  NOT NULL DEFAULT 0,
  episode       INT  NOT NULL DEFAULT 1,
  skill         INT  NOT NULL DEFAULT 2,
  tics          INT  NOT NULL DEFAULT 0,
  -- Intermission payload, all NULL outside it.
  inter_episode INT, inter_level INT, inter_next INT,
  kills_pct     INT, items_pct INT, secrets_pct INT,
  time_secs     INT, par_secs  INT,
  -- Intermission tally machine (wi_stuff.c WI_updateStats). sp_state follows
  -- vanilla: even states count a figure up, odd states are one-second pauses,
  -- and 10 waits for a keypress. The counters the screen shows are the
  -- kills_pct/items_pct/... columns above.
  sp_state         INT NOT NULL DEFAULT 0,
  cnt_pause        INT NOT NULL DEFAULT 0,
  accelerate       BOOLEAN NOT NULL DEFAULT FALSE,
  tgt_kills        INT,
  tgt_items        INT,
  tgt_secrets      INT,
  tgt_time         INT,
  tgt_par          INT,
  next_map_id      INT,
  secret_exit      BOOLEAN NOT NULL DEFAULT FALSE,
  -- Finale (f_finale.c). finale_count is the tic counter F_Ticker keeps;
  -- finale_stage is finalestage: 0 types the text out over a tiled flat, 1
  -- shows the episode's ending picture.
  finale_episode   INT,
  finale_count     INT NOT NULL DEFAULT 0,
  finale_stage     INT NOT NULL DEFAULT 0,
  -- Demo recording/playback (sql/runtime/functions/39_flow.sql): the demo
  -- being written or read, and the tic within it. D_DoAdvanceDemo's attract
  -- loop: -1 when off, else the sequence step, with the tics left on the
  -- current page. The cheat sequence buffer (doom_cheat_key).
  demo_recording   INT,
  demo_playing     INT,
  demo_tic         INT NOT NULL DEFAULT 0,
  attract_step     INT NOT NULL DEFAULT -1,
  attract_pagetic  REAL NOT NULL DEFAULT 0,
  cheat_buffer     TEXT NOT NULL DEFAULT ''
);

-- Deathmatch session: which player slot owns which player Thing. Its presence
-- is what marks a map as running a deathmatch.
CREATE TABLE IF NOT EXISTS api_roles (
  role_name TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS api_spectator_roles (
  role_name TEXT PRIMARY KEY
);

-- A slot just claimed by api_join.
CREATE TABLE IF NOT EXISTS mp_referee (
  map_id    INT PRIMARY KEY,
  heartbeat TIMESTAMPTZ NOT NULL
);

-- The one match the referee runs: which map it is on, the vanilla command
-- line it was started with (-timer, -altdeath, -nomonsters, -respawn), and
-- where it is between maps.
CREATE TABLE IF NOT EXISTS mp_match (
  id                 INT PRIMARY KEY DEFAULT 0,
  map_id             INT NOT NULL,
  skill              INT NOT NULL DEFAULT 3,
  state              match_state NOT NULL DEFAULT 'playing',
  timer_tics         INT NOT NULL DEFAULT 21000,
  altdeath           BOOLEAN NOT NULL DEFAULT TRUE,
  monsters           BOOLEAN NOT NULL DEFAULT TRUE,
  respawn_monsters   BOOLEAN NOT NULL DEFAULT TRUE,
  intermission_tics  INT NOT NULL DEFAULT 350,
  intermission_until TIMESTAMPTZ,
  maps_played        INT NOT NULL DEFAULT 0,
  -- How long one player may keep a seat while others wait; 0 means no limit.
  hold_seconds       INT NOT NULL DEFAULT 0
);

-- The map rotation
CREATE TABLE IF NOT EXISTS mp_rotation (
  position INT PRIMARY KEY,
  map_name TEXT NOT NULL
);

-- Who held which slot when a map ended?
CREATE TABLE IF NOT EXISTS mp_holders (
  slot         INT PRIMARY KEY,
  role_name    TEXT NOT NULL,
  display_name TEXT,
  claimed_at   TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS mp_waiting (
  role_name TEXT PRIMARY KEY,
  since     TIMESTAMPTZ NOT NULL,
  last_seen TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS mp_join_requests (
  map_id INT NOT NULL,
  slot   INT NOT NULL,
  PRIMARY KEY (map_id, slot)
);

CREATE TABLE IF NOT EXISTS mp_players (
  map_id          INT NOT NULL,
  slot            INT NOT NULL,
  player_thing_id INT NOT NULL,
  skill           INT NOT NULL DEFAULT 3,
  -- The database role that holds this slot, NULL while it is free. api_join
  -- claims a free slot for session_user; every api_* function and view
  -- resolves the caller through session_user -> role_name, so a client can
  -- only ever act as, and see as, the slot it holds.
  role_name       TEXT,
  pose_x          REAL NOT NULL DEFAULT 0,
  pose_y          REAL NOT NULL DEFAULT 0,
  pose_z          REAL NOT NULL DEFAULT 41,
  pose_angle      REAL NOT NULL DEFAULT 0,
  last_seen       TIMESTAMPTZ,
  display_name    TEXT,
  claimed_at      TIMESTAMPTZ,
  PRIMARY KEY (map_id, slot)
);

-- Client input, one row per client frame, consumed by the server's tic.
CREATE TABLE IF NOT EXISTS mp_inputs (
  seq             BIGSERIAL PRIMARY KEY,
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  move_fwd        REAL NOT NULL DEFAULT 0,
  move_strafe     REAL NOT NULL DEFAULT 0,
  running         BOOLEAN NOT NULL DEFAULT FALSE,
  turn_degrees    REAL NOT NULL DEFAULT 0,
  attack_held     BOOLEAN NOT NULL DEFAULT FALSE,
  weapon_switch_to INT,
  use_requested   BOOLEAN NOT NULL DEFAULT FALSE
);

-- ===== Save slots =====
-- The save file is already a set of tables, so a save is a copy:
--
-- Only authoritative state is mirrored. render_segs, render_things and
-- sector_light_fx are derived and get rebuilt on load, and the per-tic staging
-- tables (game_tic_commands, line_special_events, pickup_touches, hitscan_hits,
-- ...) are rebuilt every tic and would be meaningless in a save.
--
-- Like vanilla, a slot holds the CURRENT level only; Doom does not preserve
-- levels you have left either.
CREATE TABLE IF NOT EXISTS save_slots (
  slot            INT PRIMARY KEY,
  saved_at        TIMESTAMP NOT NULL,
  name            TEXT NOT NULL,
  map_id          INT NOT NULL,
  player_thing_id INT NOT NULL,
  map_name        TEXT,
  skill           INT NOT NULL
);

CREATE TABLE IF NOT EXISTS save_player_state AS
  SELECT 0::int AS slot, * FROM player_state WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_player_weapons AS
  SELECT 0::int AS slot, * FROM player_weapons WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_player_weapon_owned AS
  SELECT 0::int AS slot, * FROM player_weapon_owned WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_things AS
  SELECT 0::int AS slot, * FROM things WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_thing_health AS
  SELECT 0::int AS slot, * FROM thing_health WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_monster_ai AS
  SELECT 0::int AS slot, * FROM monster_ai WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_monster_projectiles AS
  SELECT 0::int AS slot, * FROM monster_projectiles WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_world_effects AS
  SELECT 0::int AS slot, * FROM world_effects WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_sectors AS
  SELECT 0::int AS slot, * FROM sectors WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_sidedefs AS
  SELECT 0::int AS slot, * FROM sidedefs WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_sector_movers AS
  SELECT 0::int AS slot, * FROM sector_movers WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_line_buttons AS
  SELECT 0::int AS slot, * FROM line_buttons WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_line_activations AS
  SELECT 0::int AS slot, * FROM line_activations WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_picked_up_items AS
  SELECT 0::int AS slot, * FROM picked_up_items WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_level_secret_discoveries AS
  SELECT 0::int AS slot, * FROM level_secret_discoveries WHERE FALSE;
CREATE TABLE IF NOT EXISTS save_level_stats AS
  SELECT 0::int AS slot, * FROM level_stats WHERE FALSE;
