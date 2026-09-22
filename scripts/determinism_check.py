#!/usr/bin/env python3
"""Assert the simulation is reproducible: same input, same world.

Nothing else in the tree checks this, and it is the property demo recording,
replay and any future attract mode all rest on. It is also easy to lose by
accident -- a new ORDER BY that does not fully order, an aggregate that picks a
representative row, a stray RANDOM() -- and the loss is silent until a replay
diverges.

Each map is played twice from a fresh reset with the same scripted input, and
the whole mutable world is hashed and compared: player, actor health, monster
AI, Thing poses, live projectiles.

  python3 scripts/determinism_check.py --dsn "..." [--tics 250] [--pairs 1]
"""
import argparse
import hashlib
import random
import sys

import psycopg2

sys.path.insert(0, __file__.rsplit("/", 2)[0])
import doom_sql as sql  # noqa: E402


WORLD = (
    "SELECT position_x,position_y,view_angle,view_z,health,armor,"
    " ammo_bullets,ammo_shells,ammo_rockets,ammo_cells"
    " FROM player_state WHERE map_id=%(m)s",
    "SELECT thing_id,health,alive FROM thing_health"
    " WHERE map_id=%(m)s ORDER BY thing_id",
    "SELECT thing_id,state,seq_index,state_tics,attack_cooldown,"
    " target_thing_id,sector_id FROM monster_ai"
    " WHERE map_id=%(m)s ORDER BY thing_id",
    "SELECT id,x,y,z,angle FROM things WHERE map_id=%(m)s ORDER BY id",
    "SELECT projectile_id,x,y,z,state,age,damage FROM monster_projectiles"
    " WHERE map_id=%(m)s ORDER BY projectile_id",
    "SELECT sector_id,plane,direction,countdown FROM sector_movers"
    " WHERE map_id=%(m)s ORDER BY sector_id,plane",
)


def world_hash(cur, map_id):
    rows = []
    for query in WORLD:
        cur.execute(query.replace("%(m)s", str(map_id)))
        rows.extend(cur.fetchall())
    return hashlib.md5(repr(rows).encode()).hexdigest()[:12]


def script(skill, tics, seed):
    """A fixed, irregular playthrough: moving, turning, firing, using."""
    rng = random.Random(seed)
    return [(
        skill,
        1.0 if rng.random() < 0.85 else 0.0,
        rng.choice((0.0, 0.0, 0.6, -0.6)),
        rng.random() < 0.6,
        rng.uniform(-7.0, 7.0),
        rng.random() < 0.3,
        rng.choice((0, 0, 0, 3, 4, 5)) or None,
        rng.random() < 0.06,
    ) for _ in range(tics)]


def play(cur, map_id, player_id, skill, commands):
    sql.reset_stage(cur, map_id, skill)
    sql.spawn_stage(cur, {"map_id": map_id, "player_thing_id": player_id})
    cur.execute("SELECT doom_cheat_arsenal(%s,%s)", (map_id, player_id))
    for command in commands:
        sql.execute_game_tic(cur, map_id, player_id, command)
    return world_hash(cur, map_id)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--tics", type=int, default=250)
    ap.add_argument("--pairs", type=int, default=1,
                    help="how many differently-seeded playthroughs per map")
    ap.add_argument("--skill", type=int, default=3, choices=(0, 1, 2, 3, 4))
    args = ap.parse_args()

    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    sql.prepare_client(cur)
    cur.execute("SELECT map_id,name FROM maps ORDER BY map_id")
    maps = cur.fetchall()

    failures = 0
    for map_id, name in maps:
        cur.execute(
            "SELECT id FROM things WHERE map_id=%s AND type=1 LIMIT 1",
            (map_id,))
        row = cur.fetchone()
        if row is None:
            print(f"  {name}: no player start, skipped")
            continue
        player_id = int(row[0])
        for seed in range(args.pairs):
            commands = script(args.skill, args.tics, seed)
            first = play(cur, map_id, player_id, args.skill, commands)
            second = play(cur, map_id, player_id, args.skill, commands)
            if first == second:
                print(f"  {name} seed {seed}: {first} reproducible")
            else:
                failures += 1
                print(f"  {name} seed {seed}: DIVERGED {first} vs {second}")

    total = len(maps) * args.pairs
    print(f"{total - failures}/{total} playthroughs reproduced exactly")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
