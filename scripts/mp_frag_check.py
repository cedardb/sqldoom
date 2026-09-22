"""Each player kills the other once with the pistol; the killer must gain a frag
and the victim keep its count (thing id 0 is a player, not the world).

Usage: mp_frag_check.py OWNER_DSN
"""
import math, sys, psycopg2
c = psycopg2.connect(sys.argv[1]); c.autocommit = True; cur = c.cursor()
MAP, SKILL = 1, 3
def duel(shooter_slot):
    cur.execute("SELECT doom_mp_start(%s,%s)", (MAP, SKILL))
    cur.execute("SELECT slot, player_thing_id FROM mp_players WHERE map_id=%s ORDER BY slot", (MAP,))
    slots = dict(cur.fetchall()); s, v = slots[shooter_slot], slots[3 - shooter_slot]
    # A fresh match opens with every slot vacant (dead); bring the two players in.
    for thing in slots.values():
        cur.execute("SELECT doom_mp_respawn(%s,%s)", (MAP, thing))
    cur.execute("SELECT position_x, position_y, view_angle, sector_id, base_z, view_z FROM player_state WHERE map_id=%s AND player_thing_id=%s", (MAP, s))
    x, y, ang, sec, bz, vz = cur.fetchone(); a = math.radians(float(ang))
    vx, vy = float(x) + 96 * math.cos(a), float(y) + 96 * math.sin(a)
    cur.execute("UPDATE player_state SET position_x=%s, position_y=%s, previous_x=%s, previous_y=%s, sector_id=%s, base_z=%s, view_z=%s WHERE map_id=%s AND player_thing_id=%s", (vx, vy, vx, vy, sec, bz, vz, MAP, v))
    cur.execute("UPDATE things SET x=%s, y=%s, z=%s WHERE map_id=%s AND id=%s", (vx, vy, bz, MAP, v))
    alive = True
    for tic in range(400):
        cur.execute("INSERT INTO mp_inputs (map_id, player_thing_id, attack_held) VALUES (%s,%s,true)", (MAP, s))
        cur.execute("SELECT doom_run_mp_tic(%s,%s,%s,%s,%s,%s)", (MAP, SKILL, slots[1], slots[2], slots.get(3), slots.get(4)))
        cur.execute("SELECT alive FROM player_state WHERE map_id=%s AND player_thing_id=%s", (MAP, v))
        alive = cur.fetchone()[0]
        if not alive: break
        # Training dummy: the shove would push the victim off the ledge.
        cur.execute("UPDATE player_state SET position_x=%s, position_y=%s, previous_x=%s, previous_y=%s, base_z=%s, view_z=%s, momentum_x=0, momentum_y=0, momentum_z=0 WHERE map_id=%s AND player_thing_id=%s", (vx, vy, vx, vy, bz, vz, MAP, v))
        cur.execute("UPDATE things SET x=%s, y=%s, z=%s, mom_x=0, mom_y=0 WHERE map_id=%s AND id=%s", (vx, vy, bz, MAP, v))
    cur.execute("SELECT player_thing_id, frags, alive, message FROM player_state WHERE map_id=%s ORDER BY player_thing_id", (MAP,))
    rows = cur.fetchall()
    print(f"  slot {shooter_slot} (thing {s}) shoots slot {3-shooter_slot} (thing {v}): victim {'dead' if not alive else 'ALIVE'} after {tic+1} tics; "
          + "; ".join(f"thing {t}: {f} frags, {'alive' if al else 'dead'}, msg={m!r}" for t, f, al, m in rows))
    frags = {t: f for t, f, _, _ in rows}
    return (not alive) and frags[s] == 1 and frags[v] == 0
ok = duel(1) and duel(2)
print("FRAGS OK" if ok else "FRAGS WRONG")
