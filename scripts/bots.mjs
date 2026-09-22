#!/usr/bin/env node
// Bot players: N guests through the relay with the page's own wire client, so
// a match has somebody in it around the clock, a visitor has somebody to
// fight, and a burn test has the load of real players: frames pulled at the
// page's rate, inputs at 35 Hz, the map rotation followed, seats left and
// retaken now and then.
//
// A bot reads what any player may read (its own state, the live overview,
// the automap lines) and plays the way the old Cajun bots did: it goes for
// the nearest opponent it can see, humans before monsters, circles at
// shotgun range, aims with a little jitter and a reaction delay, and wanders
// through doors when it sees nobody. It never takes a seat from a person:
// it joins only while a slot is free and nobody waits, and leaves within a
// few seconds once somebody does.
//
//   node scripts/bots.mjs ws://127.0.0.1:8090/pg [bots] [rejoin seconds]
//
// environment: DOOM_BOT_FPS (35; 0 pulls frames as fast as the database
// answers, the burn setting), DOOM_BOT_PARALLEL (8, the session's
// max_parallel_workers), DOOM_BOT_SKILL (0 to 1: aim and reaction, 0.6).
import { PgConnection, OID } from '../web/pgwire.js';

const [url, botsArg, rejoinArg] = process.argv.slice(2);
if (!url) { console.error('usage: bots.mjs <ws url> [bots] [rejoin seconds]'); process.exit(2); }
const BOTS = parseInt(botsArg || '2', 10);
if (!(BOTS > 0)) { console.log('no bots asked for; nothing to do'); process.exit(0); }
const REJOIN = parseFloat(rejoinArg || '900');
const FPS = parseFloat(process.env.DOOM_BOT_FPS ?? '35');
const PARALLEL = parseInt(process.env.DOOM_BOT_PARALLEL || '8', 10);
const SKILL = Math.min(1, Math.max(0, parseFloat(process.env.DOOM_BOT_SKILL ?? '0.6')));
const NAMES = ['imp', 'caco', 'baron', 'pinky', 'spectre', 'lost soul', 'zombie', 'sergeant', 'arachnotron'];
const TIC_MS = 1000 / 35;
// api_input's turn is degrees per tic, positive to the right (app.js); Doom's
// angles grow to the left, so the view angle moves by minus the turn.
const TURN_SIGN = -1;
const MAX_TURN = 10 + 8 * SKILL;          // degrees per tic, about a fast mouse
const REACTION_TICS = Math.round(18 - 12 * SKILL);
const AIM_SIGMA = 7 - 5 * SKILL;          // degrees of aim wobble, re-rolled twice a second
const SEE_RANGE = 1800;                   // map units; a sergeant's shotgun reaches farther, nobody aims that far
const FIRE_RANGE = 1300;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// When one of our own bots last asked for a seat: a refused ask sits in the
// lobby for five seconds and must not read as a person waiting.
let lastAsk = 0;
const OWN_ASK_MS = 7000;
const stamp = () => new Date().toISOString().slice(11, 19);
const norm = (deg) => ((deg + 540) % 360) - 180;
const gauss = () => { let u = 0, v = 0; while (u === 0) u = Math.random(); while (v === 0) v = Math.random(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); };

// Does the segment a-b cross any wall? Walls are the automap's one-sided
// and special lines (doors, switches), so a closed door hides what is
// behind it and a bot does not shoot at doors.
function blocked(ax, ay, bx, by, walls) {
  const dx = bx - ax, dy = by - ay;
  for (const [x1, y1, x2, y2] of walls) {
    const ex = x2 - x1, ey = y2 - y1;
    const den = dx * ey - dy * ex;
    if (den === 0) continue;
    const t = ((x1 - ax) * ey - (y1 - ay) * ex) / den;
    if (t <= 0 || t >= 1) continue;
    const u = ((x1 - ax) * dy - (y1 - ay) * dx) / den;
    if (u > 0 && u < 1) return true;
  }
  return false;
}

async function session(id) {
  // Whatever ends the session, the socket goes with it: a session that threw
  // with its WebSocket still open kept its guest seat leased at the relay for
  // as long as the bot process lived.
  const pg = new PgConnection(`${url}?guest=1`);
  try { await play(id, pg); } finally { pg.close(); }
}

async function play(id, pg) {
  const name = `BOT ${NAMES[(id - 1) % NAMES.length]}`;
  const stats = { frames: 0, empties: 0, errors: 0, ticErrors: 0, maps: new Set(), since: Date.now(), frags: 0, deaths: 0, hunting: 0, brains: 0 };
  let running = true;
  pg.onclose = (err) => { if (running) { running = false; console.log(`${stamp()} ${name}: connection closed: ${err.message}`); } };
  await pg.connect({ guest: true });
  // The browser sets this from config.json; a session left at the server
  // default fans every frame query out over all cores. Best effort, as in
  // web/app.js: builds without the setting still play, just uncapped.
  try {
    await pg.query(`SET max_parallel_workers = ${PARALLEL}`);
  } catch (e) {
    console.log(`${stamp()} ${name}: max_parallel_workers not supported by this server: ${e.message}`);
  }
  const me = pg.user;
  await pg.prepare('join', 'SELECT api_join()');
  await pg.prepare('slot', 'SELECT api_slot()');
  await pg.prepare('setname', 'SELECT api_set_name($1)', [OID.text]);
  await pg.prepare('match', 'SELECT state, map_id, map_name, waiting FROM api_match');
  await pg.prepare('seats', 'SELECT SUM(CASE WHEN connected THEN 1 ELSE 0 END), COUNT(*) FROM api_scoreboard');
  await pg.prepare('me', 'SELECT alive, position_x, position_y, view_angle, frags, ammo_bullets, ammo_shells, ammo_rockets FROM api_player_state');
  await pg.prepare('live', 'SELECT thing_id, kind, x, y FROM api_things_live WHERE map_id = $1 AND alive', [OID.int4]);
  await pg.prepare('walls', "SELECT x1, y1, x2, y2 FROM api_map_lines WHERE kind IN ('wall', 'special')");
  await pg.prepare('camera', 'SELECT api_camera($1)', [OID.float8]);
  await pg.prepare('weapon', 'SELECT api_weapon_slot($1)', [OID.int4]);
  await pg.prepare('input', 'SELECT api_input($1,$2,$3,$4,$5,$6,$7)', [OID.float4, OID.float4, OID.bool, OID.float4, OID.bool, OID.int4, OID.bool]);

  // Etiquette: take a seat only while one is free and nobody is waiting for
  // it, and ask once; a refused ask leaves a lobby row behind for five
  // seconds, which the referee would read as somebody waiting.
  let thing = -1;
  let announced = 0;
  while (running && thing < 0) {
    try {
      const [m, s] = await pg.run([{ name: 'match' }, { name: 'seats' }]);
      if (!m.rows.length || !s.rows.length) { await sleep(5000); continue; }
      const playing = m.rows[0][0] === 'playing';
      const waiting = parseInt(m.rows[0][3], 10);
      const taken = parseInt(s.rows[0][0] || '0', 10), slots = parseInt(s.rows[0][1], 10);
      if (playing && waiting === 0 && taken < slots) {
        lastAsk = Date.now();
        thing = parseInt((await pg.run([{ name: 'join' }]))[0].rows[0][0], 10);
        if (thing < 0) { await sleep(20000); continue; }
      } else {
        if (Date.now() - announced > 300000) { announced = Date.now(); console.log(`${stamp()} ${name}: standing by (${taken}/${slots} seats taken, ${waiting} waiting, ${m.rows[0][0]})`); }
        await sleep(5000);
      }
    } catch (err) {
      if (!(err.code === '40001' || /concurrent/i.test(err.message))) throw err;
      await sleep(1000);
    }
  }
  if (!running) return;
  await pg.run([{ name: 'setname', params: [name] }]);
  const slot = parseInt((await pg.run([{ name: 'slot' }]))[0].rows[0][0], 10);
  console.log(`${stamp()} ${name}: ${me} in slot ${slot} (thing ${thing})`);

  // The world as the bot knows it: sampled a few times a second, integrated
  // between samples for the angle it is turning through.
  const w = { x: 0, y: 0, angle: 0, alive: true, frags: 0, ammo: [0, 0, 0], target: null, targetSince: 0, aim: 0, goal: null, goalOffset: 0, progressDist: Infinity, walls: [], mapId: -1, leave: false, diedAt: 0, waitingSince: 0 };
  // Somebody waiting: the first bot leaves at once, the next only if they are
  // still waiting ten seconds later (one free seat is usually enough), and
  // never for one of our own refused asks.
  const someoneWaits = (waiting) => {
    if (!(waiting > 0) || Date.now() - lastAsk < OWN_ASK_MS) { w.waitingSince = 0; return; }
    if (!w.waitingSince) w.waitingSince = Date.now();
    if (Date.now() - w.waitingSince >= (id - 1) * 10000) w.leave = true;
  };
  let frameName = '', frameGen = 0;
  const prepareFrame = async (mapId) => {
    frameName = `frame${++frameGen}`;
    await pg.prepare(frameName, `SELECT frame_rgb FROM api_frame_idx_slot${slot}_m${mapId}`);
    w.mapId = mapId;
    const [lines] = await pg.run([{ name: 'walls' }]);
    w.walls = lines.rows.map((r) => r.map(parseFloat));
    w.target = null;
  };
  const readMatch = async () => {
    const [m] = await pg.run([{ name: 'match' }]);
    stats.maps.add(m.rows[0][2]);
    someoneWaits(parseInt(m.rows[0][3], 10));
    return parseInt(m.rows[0][1], 10);
  };
  await prepareFrame(await readMatch());

  // The brain, about seven times a second: where am I, who is there, whom
  // can I see. Humans before monsters, the nearest of each.
  let thinking = false;
  const think = async () => {
    if (thinking || !running) return;
    thinking = true;
    try {
      const [m, l, s] = await pg.run([{ name: 'me' }, { name: 'live', params: [w.mapId] }, { name: 'match' }]);
      stats.brains++;
      someoneWaits(parseInt(s.rows[0][3], 10));
      if (!m.rows.length) return;
      const [alive, x, y, angle, frags, bullets, shells, rockets] = m.rows[0];
      const wasAlive = w.alive;
      w.alive = alive === 't';
      if (wasAlive && !w.alive) { stats.deaths++; w.target = null; w.diedAt = Date.now(); }
      w.x = parseFloat(x); w.y = parseFloat(y); w.angle = parseFloat(angle);
      const f = parseInt(frags, 10); if (f > w.frags) stats.frags += f - w.frags; w.frags = f;
      w.ammo = [parseInt(bullets, 10), parseInt(shells, 10), parseInt(rockets, 10)];
      // The target: the nearest opponent in sight, a person before any
      // monster. The goal: the nearest opponent wherever it is, which is
      // where the bot walks when it sees nobody; monsters that see it
      // coming meet it halfway.
      let best = null, bestScore = Infinity, goal = null, goalScore = Infinity;
      for (const [tid, kind, tx, ty] of l.rows) {
        const id = parseInt(tid, 10);
        if (id === thing) continue;
        const px = parseFloat(tx), py = parseFloat(ty);
        const dist = Math.hypot(px - w.x, py - w.y);
        const score = kind === 'player' ? dist : dist + 4000;   // a person first, however far
        if (score < goalScore) { goal = { id, kind, x: px, y: py, dist }; goalScore = score; }
        if (dist > SEE_RANGE || score >= bestScore) continue;
        if (blocked(w.x, w.y, px, py, w.walls)) continue;
        best = { id, kind, x: px, y: py, dist };
        bestScore = score;
      }
      if (best && (!w.target || w.target.id !== best.id)) { w.targetSince = Date.now(); w.aim = gauss() * AIM_SIGMA; }
      w.target = best;
      if (goal && (!w.goal || w.goal.id !== goal.id)) { w.goalOffset = (Math.random() - 0.5) * 40; w.progressDist = Infinity; }
      w.goal = goal;
    } catch (err) {
      stats.ticErrors++;
    } finally { thinking = false; }
  };
  const brain = setInterval(think, 5 * TIC_MS);

  // The hands, at 35 Hz. Between samples the angle is what we last saw plus
  // the turns we sent since.
  let tic = 0, strafeDir = 1, strafeUntil = 0, wanderTurn = 0, wanderUntil = 0, lastX = NaN, lastY = NaN, lastMove = Date.now(), aimAt = 0, weaponAt = 0, sentTurn = 0, sampledAngle = NaN;
  let progressAt = 0, escapeUntil = 0, escapeTurn = 0, escapeTics = 0;
  const ticker = setInterval(() => {
    if (!running) return;
    tic++;
    const now = Date.now();
    let cmd;
    if (!w.alive) {
      // Dead: a moment on the floor, then fire to respawn.
      cmd = [0, 0, false, 0, now - (w.diedAt || 0) > 1200, null, false];
      sentTurn = 0; sampledAngle = NaN;
    } else {
      if (w.angle !== sampledAngle) { sampledAngle = w.angle; sentTurn = 0; }
      const angle = w.angle + TURN_SIGN * sentTurn;
      let fwd = 0, strafe = 0, turn = 0, fire = false, use = false, weapon = null;
      const t = w.target;
      if (t) {
        stats.hunting++;
        if (now - aimAt > 500) { aimAt = now; w.aim = gauss() * AIM_SIGMA; }
        const want = Math.atan2(t.y - w.y, t.x - w.x) * 180 / Math.PI + w.aim;
        const error = norm(want - angle);
        turn = TURN_SIGN * Math.max(-MAX_TURN, Math.min(MAX_TURN, error));
        if (now > strafeUntil) { strafeDir = Math.random() < 0.5 ? -1 : 1; strafeUntil = now + 800 + Math.random() * 1500; }
        if (t.dist > 700) { fwd = 1; strafe = strafeDir * 0.3; }
        else if (t.dist > 220) { fwd = 0.3; strafe = strafeDir; }
        else { fwd = -0.6; strafe = strafeDir; }
        const settled = now - w.targetSince > REACTION_TICS * TIC_MS;
        fire = settled && Math.abs(error) < 6 && t.dist < FIRE_RANGE && (tic % 14) < 10;
        if (now - weaponAt > 3000) {
          weaponAt = now;
          const [bullets, shells, rockets] = w.ammo;
          const order = [];
          if (rockets > 0 && t.dist > 450) order.push(5);
          if (bullets >= 10) order.push(4);
          if (shells > 0) order.push(3);
          if (bullets > 0) order.push(2);
          order.push(1);
          (async () => { for (const s of order) { const [r] = await pg.run([{ name: 'weapon', params: [s] }]); if (parseInt(r.rows[0][0], 10) >= 0) return; } })().catch(() => {});
        }
      } else if (w.goal) {
        // Nobody in sight: walk toward the nearest opponent. Doom slides a
        // player along walls, so "stuck" is not standing still but making no
        // headway: then press use (a door, perhaps), turn well away and walk
        // that way for a moment before steering back.
        fwd = 1;
        const dist = Math.hypot(w.goal.x - w.x, w.goal.y - w.y);
        if (now > progressAt) {
          if (dist > w.progressDist - 24 && now > escapeUntil) {
            use = true;
            escapeTurn = TURN_SIGN * (Math.random() < 0.5 ? -1 : 1) * (7 + Math.random() * 6);
            escapeTics = 10;
            escapeUntil = now + 1500 + Math.random() * 1500;
          }
          w.progressDist = dist; progressAt = now + 1200;
        }
        if (now < escapeUntil) {
          turn = escapeTics-- > 0 ? escapeTurn : 0;
        } else {
          const want = Math.atan2(w.goal.y - w.y, w.goal.x - w.x) * 180 / Math.PI + w.goalOffset;
          turn = TURN_SIGN * Math.max(-MAX_TURN, Math.min(MAX_TURN, norm(want - angle)));
        }
        use = use || (tic % 70 === 0);
      } else {
        // Nobody anywhere: walk, and turn away from whatever stops us.
        fwd = 1;
        const moved = Math.hypot(w.x - lastX, w.y - lastY);
        if (w.x !== lastX || w.y !== lastY) { if (moved > 2) lastMove = now; lastX = w.x; lastY = w.y; }
        if (now - lastMove > 700 && now > wanderUntil) {
          use = true;
          wanderTurn = TURN_SIGN * (Math.random() < 0.5 ? -1 : 1) * (6 + Math.random() * 6);
          wanderUntil = now + (8 + Math.random() * 10) * TIC_MS;
          lastMove = now;
        } else if (now > wanderUntil && Math.random() < 0.01) {
          wanderTurn = TURN_SIGN * (Math.random() - 0.5) * 8;
          wanderUntil = now + 6 * TIC_MS;
        }
        turn = now < wanderUntil ? wanderTurn : 0;
        use = use || (tic % 70 === 0);
      }
      sentTurn += turn;
      cmd = [fwd, strafe, true, turn, fire, weapon, use];
    }
    pg.run([{ name: 'input', params: cmd }]).catch(() => { stats.ticErrors++; });
  }, TIC_MS);

  // The eyes: frames at the page's rate. An empty frame means the slot is
  // gone or the map changed.
  const leaveAt = Date.now() + (REJOIN * (0.5 + Math.random())) * 1000;
  let lastLine = Date.now(), next = Date.now();
  while (running && Date.now() < leaveAt && !w.leave) {
    try {
      const [, fr] = await pg.run([{ name: 'camera', params: [0.5] }, { name: frameName, binary: true }]);
      const frame = fr.rows[0] && fr.rows[0][0];
      if (!frame) {
        stats.empties++;
        const held = parseInt((await pg.run([{ name: 'slot' }]))[0].rows[0][0], 10);
        if (held !== slot) { console.log(`${stamp()} ${name}: slot ${slot} was taken back`); break; }
        const mapId = await readMatch();
        if (mapId !== w.mapId) await prepareFrame(mapId);
        await sleep(100);
        continue;
      }
      stats.frames++;
      if (FPS > 0) { next += 1000 / FPS; const d = next - Date.now(); if (d > 0) await sleep(d); else next = Date.now(); }
    } catch (err) {
      stats.errors++;
      if (stats.errors <= 3) console.log(`${stamp()} ${name}: frame error: ${err.message}`);
      await sleep(200);
    }
    if (Date.now() - lastLine >= 60000) {
      const secs = (Date.now() - stats.since) / 1000;
      const hunting = stats.brains ? Math.round(100 * stats.hunting / (secs * 35)) : 0;
      console.log(`${stamp()} ${name}: ${(stats.frames / secs).toFixed(1)} fps, ${stats.frags} frags, ${stats.deaths} deaths, hunting ${hunting}% of the time, ${stats.empties} empty, ${stats.errors} frame errors, ${stats.ticErrors} tic errors, maps ${[...stats.maps].join('>')}`);
      stats.frames = 0; stats.empties = 0; stats.errors = 0; stats.ticErrors = 0; stats.frags = 0; stats.deaths = 0; stats.hunting = 0; stats.brains = 0; stats.since = Date.now(); lastLine = Date.now();
    }
  }
  clearInterval(ticker); clearInterval(brain);
  running = false;
  console.log(`${stamp()} ${name}: leaving ${me} (slot ${slot})${w.leave ? ' for somebody waiting' : ''}`);
}

async function bot(id) {
  await sleep((id - 1) * 3000);
  for (;;) {
    try { await session(id); } catch (err) { console.log(`${stamp()} bot ${id}: session failed: ${err.message}`); }
    // After leaving for a waiter, stay away long enough for them to sit down.
    await sleep(15000 + Math.random() * 15000);
  }
}
console.log(`${stamp()} ${BOTS} bots -> ${url}, skill ${SKILL}, ${FPS || 'unpaced'} fps, a seat is given up about every ${REJOIN} s`);
await Promise.all(Array.from({ length: BOTS }, (_, i) => bot(i + 1)));
