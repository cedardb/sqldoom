#!/usr/bin/env python3
"""Exercise the imported SQL-owned game pipeline on a disposable database."""

import argparse
from pathlib import Path
import sys

import psycopg2


PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

import doom_sql as sql  # noqa: E402


EXPECTED_CATALOG_COUNTS = {
    "thing_sprite_defs": 116,
    "thing_combat_defs": 21,
    "thing_ai_frames": 102,  # + the xdeath (gib) animations
    "pickup_defs": 35,   # + the computer map and the light amp visor
    "weapon_defs": 8,
    "weapon_frames": 51,
}


def catalog_counts(cur):
    counts = {}
    for table, expected in EXPECTED_CATALOG_COUNTS.items():
        cur.execute(f"SELECT COUNT(*) FROM {table}")
        actual = int(cur.fetchone()[0])
        if actual != expected:
            raise AssertionError(f"{table}: expected {expected}, got {actual}")
        counts[table] = actual
    return counts


def select_stage(cur, label):
    stages = sql.load_stages(cur)
    for stage in stages:
        if stage["label"].split(" — ", 1)[0].upper() == label.upper():
            return stage
    available = ", ".join(stage["label"] for stage in stages) or "none"
    raise RuntimeError(f"map {label!r} is unavailable; loaded maps: {available}")


def run(dsn, map_name, skill, attack_tics):
    with psycopg2.connect(dsn) as conn:
        with conn.cursor() as cur:
            counts = catalog_counts(cur)
            stage = select_stage(cur, map_name)
            map_id = stage["map_id"]
            player_id = stage["player_thing_id"]
            sql.prepare_client(cur)

            idle = (skill, 0.0, 0.0, False, 0.0, False, 0, False)
            attack = (skill, 0.0, 0.0, False, 0.0, True, 0, False)

            # Exercise the first executions before restoring a pristine stage.
            sql.reset_stage(cur, map_id, skill)
            sql.spawn_stage(cur, stage)
            sql.record_level_secret(cur, map_id, player_id)
            for _ in range(2):
                sql.execute_game_tic(cur, map_id, player_id, idle)
                sql.finish_game_tic(cur, map_id, player_id)

            sql.reset_stage(cur, map_id, skill)
            pose = sql.spawn_stage(cur, stage)
            sql.record_level_secret(cur, map_id, player_id)
            cur.execute(
                "SELECT ammo_bullets FROM player_state "
                "WHERE map_id=%s AND player_thing_id=%s",
                (map_id, player_id),
            )
            starting_ammo = int(cur.fetchone()[0])

            for _ in range(attack_tics):
                sql.execute_game_tic(cur, map_id, player_id, attack)
                snapshot = sql.finish_game_tic(cur, map_id, player_id)

            cur.execute(
                "SELECT w.shot_serial,p.ammo_bullets "
                "FROM player_weapons w "
                "JOIN player_state p USING(map_id,player_thing_id) "
                "WHERE w.map_id=%s AND w.player_thing_id=%s",
                (map_id, player_id),
            )
            shot_serial, ending_ammo = map(int, cur.fetchone())
            if shot_serial <= 0 or ending_ammo >= starting_ammo:
                raise AssertionError(
                    "prepared weapon tick did not fire and consume ammunition"
                )
            if not snapshot["alive"]:
                raise AssertionError("player died during stationary smoke test")
            if not sql.load_automap(cur, map_id)["lines"]:
                raise AssertionError("automap projection returned no lines")
            if sql.fetch_stage_music(cur, map_id) is None:
                raise AssertionError("stage music projection returned no row")

    with psycopg2.connect(dsn) as conn:
        with conn.cursor() as cur:
            sql.prepare_renderer(cur)
            sql.prepare_render_stats(cur)
            stats = sql.fetch_render_stats(
                cur, map_id, player_id, skill,
                (snapshot["x"], snapshot["y"], snapshot["z"],
                 snapshot["angle"]),
            )
            if not stats or stats["pixels_resolved"] <= 0:
                raise AssertionError(
                    "renderer stats projection returned nothing"
                )
            frame = sql.render_frame(
                cur, map_id, player_id, skill,
                (snapshot["x"], snapshot["y"], snapshot["z"],
                 snapshot["angle"]),
            )

    print(f"map: {stage['label']} at {tuple(round(v, 2) for v in pose)}")
    print("catalogs:", ", ".join(f"{name}={count}" for name, count in counts.items()))
    print(f"weapon: shots={shot_serial}, bullets={starting_ammo}->{ending_ammo}")
    print(f"renderer: {len(frame)} bytes")
    print(f"stats: {stats['fragments_ranked']} fragments ranked, "
          f"{stats['pixels_resolved']} pixels resolved, "
          f"{stats['holes']} uncovered")
    print("prepared pipeline: ok")


def main():
    parser = argparse.ArgumentParser(
        description="Destructively reset one imported map and test its prepared pipeline."
    )
    parser.add_argument("--dsn", required=True)
    parser.add_argument("--map", default="E1M1")
    parser.add_argument("--skill", type=int, choices=(0, 1, 2, 3, 4),
                        default=2)
    parser.add_argument("--attack-tics", type=int, default=40)
    args = parser.parse_args()
    run(args.dsn, args.map, args.skill, args.attack_tics)


if __name__ == "__main__":
    main()
