"""Client configuration: environment, timing and the shared connection knobs.

Everything here is read by more than one module (the client, the render
worker, the dock, the deathmatch server), so it lives in one place.
"""
import os

DB_DSN = os.getenv("DB_DSN", "dbname=postgres user=postgres host=localhost port=5432")
SCREEN_W = int(os.getenv("SCREEN_W", 320))
SCREEN_H = int(os.getenv("SCREEN_H", 200))
# Integer window scale; unset picks the largest that fits the desktop.
WINDOW_SCALE = os.getenv("WINDOW_SCALE")
MOUSE_SENSITIVITY = float(os.getenv("MOUSE_SENSITIVITY", "0.15"))
MAP_ID = int(os.getenv("MAP_ID", 1))
# Deathmatch client: DOOM_JOIN=1 or 2 joins the match doom_server.py is running
# on MAP_ID as that player. The server owns the tic; this client renders its
# own view and pushes its input into the database.
JOIN_SLOT = int(os.getenv("DOOM_JOIN", 0))
DEFAULT_SKILL = 2

# pipeline: doom_cs_plan returns a bitmask of what is due and is re-evaluated
# four times per tic, so most tics skip most stages. Bits match the mask
# accumulated in sql/runtime/functions/40_run_game_tic.sql.
#
# (bit, label, group). Groups are drawn as separate clusters: the stages that
# run unconditionally, and the ones the planner gates.
TIC_STAGES = (
    (1,      "begin",    "always"),
    (2,      "clock",    "always"),
    (4,      "plan",     "always"),
    (8,      "use",      "world"),
    (16,     "specials", "world"),
    (32,     "movers",   "world"),
    (128,    "move",     "player"),
    (256,    "turn",     "player"),
    (512,    "secrets",  "player"),
    (1024,   "walkover", "player"),
    (2048,   "pickups",  "player"),
    (4096,   "weapon",   "combat"),
    (8192,   "hitscan",  "combat"),
    (16384,  "damage",   "combat"),
    (32768,  "missiles", "combat"),
    (65536,  "sound",    "always"),
    (131072, "monsters", "always"),
    (262144, "sectors",  "always"),
    (524288, "physics",  "always"),
)

# Catch-up cap after a stall, so a stalled client does not spiral.
MAX_TICS_PER_FRAME = 4

# Gameplay numbers belong to the database (doom_constants, loaded by
# wad_loader); restating them here is how a client and the tic it drives drift
# apart. load_constants fills these in from the connection the caller has just
# opened, before anything reads them.
TICS_PER_SECOND = None
TIC_SECONDS = None
TURN_DEGREES_PER_TIC = None

GAMEPLAY_CONSTANTS = ("TICRATE", "TURN_DEGREES_PER_TIC")


def load_constants(cur):
    """Read the gameplay constants this module publishes out of the database."""
    global TICS_PER_SECOND, TIC_SECONDS, TURN_DEGREES_PER_TIC
    cur.execute("SELECT name, value FROM doom_constants")
    values = {name: float(value) for name, value in cur.fetchall()}
    missing = [name for name in GAMEPLAY_CONSTANTS if name not in values]
    if missing:
        raise RuntimeError("doom_constants is missing " + ", ".join(missing))
    TICS_PER_SECOND = values["TICRATE"]
    TIC_SECONDS = 1.0 / TICS_PER_SECOND
    TURN_DEGREES_PER_TIC = values["TURN_DEGREES_PER_TIC"]

# CedarDB rechecks every prepared statement for a better plan once the
# optimizer.replantimems interval has elapsed (default 60 s).
# Replanning the renderer costs about 1.25 s.
# Since the optimal plan shoulnd't change (the dataset is very small anyway)
# we just don't replan by setting the replan interval very high.
REPLAN_MS = int(os.getenv("REPLAN_MS", "86400000"))


def tune_replanning(cur):
    """Stop the once-a-minute replan stall."""
    if REPLAN_MS <= 0:
        return
    try:
        cur.execute(f"SET debug.optimizer.replantimems = {REPLAN_MS:d}")
    except Exception:
        cur.connection.rollback()
