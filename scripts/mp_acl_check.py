"""What a player role can and cannot do, statement by statement.

Usage: mp_acl_check.py OWNER_DSN PLAYER1_DSN PLAYER2_DSN
Run after scripts/setup_roles.py with a referee (doom_server.py) open.
"""
import sys, psycopg2
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import doom_sql as sql  # noqa: E402
ADMIN, p1, p2 = sys.argv[1], sys.argv[2], sys.argv[3]
def tryq(cur,conn,label,q,args=(),expect_ok=True):
    try:
        cur.execute(q,args); r=cur.fetchall() if cur.description else "ok"; ok=True; note=str(r)[:70]
    except Exception as e:
        conn.rollback(); ok=False; note=str(e).strip().splitlines()[0][:80]
    verdict="as expected" if ok==expect_ok else "*** UNEXPECTED ***"
    print(f"  {'allowed ' if ok else 'denied  '} {label:<52} {verdict}   {note}")
    return ok==expect_ok
c1=psycopg2.connect(p1); c1.autocommit=True; k1=c1.cursor()
c2=psycopg2.connect(p2); c2.autocommit=True; k2=c2.cursor()
results=[]
print("player 1:")
for label,q,args,exp in (
    ("SELECT api_join()","SELECT api_join()",(),True),
    ("read own snapshot view","SELECT alive FROM api_snapshot",(),True),
    ("read own player_state view","SELECT health FROM api_player_state",(),True),
    ("read player_state table","SELECT count(*) FROM player_state",(),False),
    ("read things table","SELECT count(*) FROM things",(),False),
    ("read the other slot's frame view (no frame for a non-holder)","SELECT count(frame_rgb) FROM api_frame_idx_slot2_m1",(),True),
    ("read own frame view","SELECT octet_length(frame_rgb) FROM api_frame_slot1_m1",(),True),
    ("read own indexed frame view","SELECT octet_length(frame_rgb) FROM api_frame_idx_slot1_m1",(),True),
    ("read the palettes","SELECT count(*) FROM api_palettes",(),True),
    ("read the scoreboard","SELECT count(*) FROM api_scoreboard",(),True),
    ("api_slot","SELECT api_slot()",(),True),
    ("api_camera","SELECT api_camera(0.5::float8)",(),True),
    # The camera is the server's to compute. api_pose let a client name its
    # own (x,y,z,angle) and render from anywhere on the map; it is gone, and
    # api_camera takes only the interpolation alpha, which it clamps to [0,1].
    ("name my own camera with api_pose",
     "SELECT api_pose(0::float8,0::float8,0::float8,0::float8)",(),False),
    ("api_camera with alpha out of range","SELECT api_camera(9999.0::float8)",(),True),
    # Likewise the automap: reveal_all is the caller's own computer-map
    # powerup, and IDDT is not on offer at all.
    ("ask the automap for reveal_all + IDDT",
     "SELECT api_automap(0::float8,0::float8,0.1::float8,true,2,false)",(),False),
    ("draw the automap I am entitled to",
     "SELECT octet_length(api_automap(0::float8,0::float8,0.1::float8,false))",(),True),
    ("give myself the computer map","UPDATE player_state SET power_map=true",(),False),
    ("push input via api_input","SELECT api_input(1.0::real,0.0::real,false,0.0::real,true,NULL::int,false)",(),True),
    ("insert mp_inputs for another slot directly","INSERT INTO mp_inputs (map_id,player_thing_id) VALUES (1,1)",(),False),
    ("give myself health","UPDATE player_state SET health=999",(),False),
    ("run the tic","SELECT doom_run_mp_tic(1,3,0,1,NULL,NULL)",(),False),
    ("cheat","SELECT doom_cheat(1,0,'IDDQD')",(),False),
    ("reset the level","SELECT doom_reset_stage(1,3)",(),False),
    ("open a match","SELECT doom_mp_start(1,3)",(),False),
    ("read sound events view","SELECT count(*) FROM api_sound_events",(),True),
    ("read the wall geometry","SELECT count(*) FROM linedef_geom",(),False),
    ("create a role","CREATE ROLE evil LOGIN PASSWORD 'Evil-Pw-2026!xx'",(),False),
    ("set the replan knob","SET debug.optimizer.replantimems = 1000",(),False),
):
    r=tryq(k1,c1,label,q,args,exp)
    results.append(r)
print("player 2 input lands on slot 2 only (admin view of the queue):")
k2.execute("SELECT api_join()"); print("  player 2 joined as thing", k2.fetchone()[0])
k2.execute("SELECT api_input(0.0::real,0.0::real,false,0.0::real,false,NULL::int,true)")
a=psycopg2.connect(ADMIN); a.autocommit=True; ka=a.cursor()
ka.execute("SELECT player_thing_id, count(*) FROM mp_inputs GROUP BY player_thing_id ORDER BY 1"); rows=ka.fetchall(); print("  mp_inputs by player:",rows)
ka.execute("SELECT slot, role_name, player_thing_id FROM mp_players ORDER BY slot"); print("  slots:",ka.fetchall())
ka.execute("DELETE FROM mp_inputs")
print("ALL AS EXPECTED" if all(results) else "SOME CHECKS FAILED")
sys.exit(0 if all(results) else 1)
