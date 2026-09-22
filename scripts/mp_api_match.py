"""Deathmatch integration with real roles: referee as owner, one bot client per
   player DSN given (up to four) through the API only (aim uses an admin cursor,
   which is the test's privilege, not the client's)."""
import os,sys,time,math,subprocess,statistics,multiprocessing as mp,psycopg2,select
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
# Usage: mp_api_match.py OWNER_DSN MAP SECONDS PLAYER_DSN [PLAYER_DSN ...]
ADMIN=sys.argv[1]; MAP=int(sys.argv[2]); SECONDS=float(sys.argv[3]); DSNS={i+1:d for i,d in enumerate(sys.argv[4:])}
def bot(slot,start,stop,q):
    import doom_sql as sql; sql.API_MODE=True
    c=psycopg2.connect(DSNS[slot]); c.autocommit=True; k=c.cursor(); sql.prepare_client(k)
    me=None
    while me is None: me=sql.api_join(k); time.sleep(0.2)
    a=psycopg2.connect(ADMIN); a.autocommit=True; ka=a.cursor()
    sql.prepare_renderer(k,MAP,me,3)
    snap=sql.finish_game_tic(k,MAP,me); pose=(snap["x"],snap["y"],snap["z"],snap["angle"])
    # keep rendering (and so heart-beating) until every bot is ready: a silent
    # wait longer than IDLE_SECONDS would hand the slot back
    while not start.wait(0.5): sql.render_frame(k,MAP,me,3,pose)
    frames=[]; last_sound=0; sounds=0; deaths=0; was_alive=True; tics=0; nxt=time.perf_counter(); errors=0
    while not stop.is_set():
        try:
            snap=sql.finish_game_tic(k,MAP,me); x,y,ang,z,alive=snap["x"],snap["y"],snap["angle"],snap["z"],snap["alive"]
            # chase the nearest other player who is in the match (an occupied slot)
            ka.execute("SELECT t.x,t.y,ps.alive FROM mp_players mp JOIN things t ON t.map_id=mp.map_id AND t.id=mp.player_thing_id JOIN player_state ps ON ps.map_id=t.map_id AND ps.player_thing_id=t.id WHERE mp.map_id=%s AND mp.player_thing_id<>%s AND mp.role_name IS NOT NULL ORDER BY (t.x-%s)^2+(t.y-%s)^2 LIMIT 1",(MAP,me,x,y)); row=ka.fetchone()
            if row is None: ox,oy,oalive=x+100,y,False
            else: ox,oy,oalive=float(row[0]),float(row[1]),row[2]
            if was_alive and not alive: deaths+=1
            was_alive=alive
            want=math.degrees(math.atan2(oy-y,ox-x)); turn=((want-ang+180)%360)-180; dist=math.hypot(ox-x,oy-y)
            cmd=(3, 1.0 if dist>160 else 0.0, 0.0, True, -max(-12.0,min(12.0,turn)), abs(turn)<8 and oalive, None, False)
            if not alive: cmd=(3,0.0,0.0,False,0.0,True,None,True)
            sql.mp_push_input(k,MAP,me,cmd); tics+=1
            ev,_=sql.fetch_sound_events(k,MAP,me,last_sound)
            if ev: last_sound=max(int(r[0]) for r in ev); sounds+=len(ev)
            cam=sql.camera_pose(k,MAP,me,0.5) or (x,y,z,ang)
            t=time.perf_counter(); sql.render_frame(k,MAP,me,3,cam); frames.append((time.perf_counter()-t)*1000)
        except Exception as e:
            errors+=1; c.rollback()
            if errors<3: print(f"  bot {slot} error: {str(e).strip().splitlines()[0][:100]}",flush=True)
        nxt+=1/35; d=nxt-time.perf_counter()
        if d>0: time.sleep(d)
        else: nxt=time.perf_counter()
    q.put((slot,frames,sounds,deaths,tics,errors))
if __name__=="__main__":
    env=dict(os.environ,DB_DSN=ADMIN,MAP_ID=str(MAP),SKILL="3",PYTHONPATH=REPO)
    srv=subprocess.Popen([sys.executable,os.path.join(REPO,"doom_server.py")],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    ready=False; t0=time.time()
    while time.time()-t0<120:
        line=srv.stdout.readline(); print("  server:",line.rstrip())
        if "ready in" in line: ready=True; break
        if srv.poll() is not None: break
    if not ready: print("SERVER FAILED"); print(srv.stdout.read()); sys.exit(1)
    start=mp.Event(); stop=mp.Event(); q=mp.Queue()
    bots=[mp.Process(target=bot,args=(s,start,stop,q)) for s in sorted(DSNS)]
    for b in bots: b.start()
    time.sleep(6); start.set(); t0=time.perf_counter()
    while time.perf_counter()-t0<SECONDS:
        r,_,_=select.select([srv.stdout],[],[],0.5)
        if r:
            line=srv.stdout.readline()
            if line: print("  server:",line.rstrip())
    stop.set(); wall=time.perf_counter()-t0
    res=sorted([q.get() for _ in bots])
    for b in bots: b.join()
    a=psycopg2.connect(ADMIN); a.autocommit=True; ka=a.cursor()
    ka.execute("SELECT mp.slot, mp.role_name, ps.frags, ps.health, ps.alive FROM mp_players mp JOIN player_state ps ON ps.map_id=mp.map_id AND ps.player_thing_id=mp.player_thing_id WHERE mp.map_id=%s ORDER BY mp.slot",(MAP,)); score=ka.fetchall()
    for slot,frames,sounds,deaths,tics,errors in res:
        fr=sorted(frames) or [0]
        print(f"  bot {slot}: {len(frames)/wall:5.1f} fps (frame median {fr[len(fr)//2]:5.1f} ms, p90 {fr[int(len(fr)*.9)]:5.1f}), {tics} inputs, {sounds} sounds, died {deaths}x, errors {errors}")
    print("  scoreboard:",score)
    srv.terminate(); srv.wait(timeout=10)
