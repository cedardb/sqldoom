"""SQL-owned catalog and import-time materialization for the WAD loader."""

from functools import cache
from pathlib import Path


ROOT = Path(__file__).resolve().parent / "sql" / "loader"
FUNCTION_FILES = (
    "functions/00_materialize_render_segs.sql",
    "functions/01_materialize_render_things.sql",
    "functions/02_materialize_all_render_things.sql",
)


@cache
def load_sql(filename):
    return (ROOT / filename).read_text(encoding="utf-8")


def install_loader_functions(cur):
    for filename in FUNCTION_FILES:
        cur.execute(load_sql(filename))


def load_game_data(cur):
    cur.execute(load_sql("game_data.sql"))
    cur.execute(load_sql("menu_data.sql"))
    # Recorded demos are not in the tree: a demo is an input stream the world
    # is recomputed from, so it only replays while the simulation it was
    # recorded against is unchanged, and gameplay fixes retire it. Record one
    # with F9, freeze it with scripts/gen_demo_data.py, and every import from
    # then on picks the file up. Without it the attract loop shows the title
    # pages and nothing else changes.
    if (ROOT / "demo_data.sql").exists():
        cur.execute(load_sql("demo_data.sql"))


def stamp_line_specials(cur):
    """Copy the catalogue's hot-path flags onto every linedef."""
    cur.execute("""
        UPDATE linedefs ld
        SET cross_activated   = d.cross_activated,
            cross_once        = d.cross_once,
            monster_crossable = d.monster_crossable,
            scrolls           = d.scrolls
        FROM line_special_defs d
        WHERE d.special = ld.special
          AND (ld.cross_activated   <> d.cross_activated
            OR ld.cross_once        <> d.cross_once
            OR ld.monster_crossable <> d.monster_crossable
            OR ld.scrolls           <> d.scrolls)
    """)


def materialize_render_segs(cur, map_id):
    cur.execute("SELECT doom_materialize_render_segs(%s)", (map_id,))
    cur.fetchone()


def refresh_derived(cur):
    for view in ("linedef_geom", "sector_adjacency", "node_path_steps"):
        cur.execute(f"REFRESH MATERIALIZED VIEW {view}")


def materialize_ui_pixels(cur):
    cur.execute("REFRESH MATERIALIZED VIEW ui_hud_pixels")
    cur.execute("REFRESH MATERIALIZED VIEW ui_static_pixels")


def materialize_render_things(cur, map_id=None):
    if map_id is None:
        cur.execute("SELECT doom_materialize_all_render_things()")
    else:
        cur.execute("SELECT doom_materialize_render_things(%s)", (map_id,))
    cur.fetchone()
