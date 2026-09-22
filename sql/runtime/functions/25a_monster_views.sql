CREATE OR REPLACE VIEW doom_player_shadow AS
SELECT ps.map_id, ps.player_thing_id,
       (ps.invis_tics > 0) AS shadowed, ps.level_tics
FROM player_state ps;

CREATE OR REPLACE VIEW doom_player_pos AS
SELECT t.map_id, t.id AS player_thing_id,
       t.x::double precision AS px, t.y::double precision AS py
FROM things t;

CREATE OR REPLACE VIEW doom_monster_attackers AS
SELECT ai.map_id, ai.thing_id, t.type,
       t.x::double precision AS mx, t.y::double precision AS my,
       d.hitscan_pellets, d.melee_mult, d.melee_sides, d.explodes,
       d.blast_radius,
       d.hitscan_mult, d.hitscan_sides
FROM monster_ai ai
JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
JOIN thing_combat_defs d ON d.thing_type = t.type
WHERE ai.fired_this_tick;
