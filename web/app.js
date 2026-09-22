// The browser client. It is the native client's join mode with the pygame
// parts swapped for a canvas and WebAudio: read the keyboard and mouse, hand
// the database one input row per 35 Hz tic, ask it for the camera and a frame
// as fast as it answers, blit, and play the sounds it reports. Every rule is
// SQL; this file holds no game logic. Even the camera interpolation is the
// database's (api_camera), so the browser never knows where it stands.
import { PgConnection, OID } from './pgwire.js';

const TIC_MS = 1000 / 35;
const TURN_DEGREES_PER_TIC = 3.2;
const MOUSE_SENSITIVITY = 0.15;
const W = 320, H = 200;
const FRAMES_IN_FLIGHT = 2;   // see the frame loop; a third request only queued (measured over a 36 ms tailnet)
// The frame loop asks as fast as the database answers, which on a wide box
// is well past Doom's own 35 Hz. Every frame is 64 KB before the tunnel's
// coding, so the cap is the one knob on egress; config.json (max_fps, from
// the relay's DOOM_MAX_FPS) sets it, 0 means none.
let maxFps = 35;

const $ = (id) => document.getElementById(id);
const ui = {
  form: $('connect'), status: $('status'), stage: $('stage'), canvas: $('screen'),
  nick: $('nick'), nickField: $('nick-field'), userField: $('user-field'), passwordField: $('password-field'),
  accountToggle: $('account-toggle'),
  overlay: $('overlay'), overlayText: $('overlay-text'), score: $('scoreboard'), lobbyMap: $('lobby-map'),
  stats: $('stats'), target: $('target'), user: $('user'), password: $('password'),
  button: $('go'), targetField: $('target-field'), help: $('help'),
};
const ctx = ui.canvas.getContext('2d', { alpha: false });
const image = ctx.createImageData(W, H);
const pixels = new Uint32Array(image.data.buffer);

let pg = null;
let clientParallel = null;   // from config.json: SET max_parallel_workers for this connection
let guestSeats = 0;          // from config.json: guest logins the relay can hand out
let accountMode = true;
let audio = null;
let running = false;
let embedded = false;        // ?embed=1 inside another page's iframe (the cloud demo's Deathmatch tab)

// Embedded, the page is only the screen: the host page draws the name field,
// the button and the two text lines in its own style and hears about them
// here. Messages carry no game state a player could act on; the host has the
// spectator's SQL for that.
const post = (kind, data = {}) => {
  if (!embedded) return;
  try { window.parent.postMessage({ source: 'sqldoom', kind, ...data }, '*'); } catch (e) { /* no parent */ }
};
const status = (text, bad = false) => {
  ui.status.textContent = text; ui.status.classList.toggle('bad', bad);
  post('status', { text, bad });
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------- input state
const keys = new Set();
const input = { mouseTurn: 0, pendingWeapon: null, pendingUse: false, wheel: 0, weaponKey: null, fireHeld: false };
const automap = { on: false };
const amPending = [];                // view changes to send with the next frame
let scoreHeld = false, dead = false, inLobby = false, intermission = false;
function refreshScore() { ui.score.hidden = !(scoreHeld || dead || inLobby || intermission); }

function isTyping() { return document.activeElement && document.activeElement.tagName === 'INPUT'; }

window.addEventListener('keydown', (ev) => {
  if (!running || isTyping()) return;
  if (ev.code === 'Tab') {
    ev.preventDefault();
    if (ev.shiftKey) { scoreHeld = true; refreshScore(); return; }
    if (!ev.repeat) automap.on = !automap.on;
    return;
  }
  if (ev.repeat) { ev.preventDefault(); return; }
  keys.add(ev.code);
  if (ev.code === 'Space') input.pendingUse = true;
  if (/^Digit[1-7]$/.test(ev.code)) input.weaponKey = parseInt(ev.code[5], 10);
  if (automap.on) {
    if (ev.code === 'KeyF') amPending.push({ name: 'am_toggle', params: ['follow'] });
    if (ev.code === 'KeyG') amPending.push({ name: 'am_toggle', params: ['grid'] });
    if (ev.code === 'Home') amPending.push({ name: 'am_fit', params: [] });
    if (ev.code === 'Equal' || ev.code === 'NumpadAdd') amPending.push({ name: 'am_zoom', params: [1.25] });
    if (ev.code === 'Minus' || ev.code === 'NumpadSubtract') amPending.push({ name: 'am_zoom', params: [1 / 1.25] });
  }
  if (!['F5', 'F11', 'F12'].includes(ev.code)) ev.preventDefault();
});
window.addEventListener('keyup', (ev) => {
  if (ev.code === 'Tab') { ev.preventDefault(); scoreHeld = false; refreshScore(); }
  keys.delete(ev.code);
});
window.addEventListener('blur', () => keys.clear());
// The mouse: a click on the screen locks the pointer while playing. Chrome
// returns a promise and refuses for reasons worth reading (an iframe without
// the permission, a request too soon after Esc); say so instead of nothing.
let lockAsksWithPromise = false;   // Chrome says why in the promise; the error event then only repeats it
ui.canvas.addEventListener('click', () => {
  if (!running) return;
  try {
    const p = ui.canvas.requestPointerLock();
    if (p && p.catch) {
      lockAsksWithPromise = true;
      p.catch((err) => status(`mouse capture refused: ${err.message}`, true));
    }
  } catch (err) { status(`mouse capture refused: ${err.message}`, true); }
});
document.addEventListener('pointerlockchange', () => {
  const locked = document.pointerLockElement === ui.canvas;
  post('pointer', { locked });
  if (running) status(locked ? 'mouse captured; Esc releases it' : 'mouse released; click the screen to capture it again');
});
document.addEventListener('pointerlockerror', () => {
  if (!lockAsksWithPromise) status('mouse capture failed; click the screen again', true);
});
ui.canvas.addEventListener('mousedown', (ev) => { if (ev.button === 0 && document.pointerLockElement === ui.canvas) input.fireHeld = true; });
window.addEventListener('mouseup', (ev) => { if (ev.button === 0) input.fireHeld = false; });
window.addEventListener('mousemove', (ev) => {
  if (document.pointerLockElement === ui.canvas) input.mouseTurn += ev.movementX * MOUSE_SENSITIVITY;
});
ui.canvas.addEventListener('wheel', (ev) => {
  if (!running) return;
  if (automap.on) amPending.push({ name: 'am_zoom', params: [Math.pow(1.15, -Math.sign(ev.deltaY))] });
  else input.wheel += Math.sign(ev.deltaY);
  ev.preventDefault();
}, { passive: false });

const down = (...codes) => codes.some((c) => keys.has(c));

function readCommand(alive) {
  const enabled = alive;
  // With the automap up the arrows pan it instead.
  const arrowsPan = automap.on;
  if (arrowsPan) {
    const dx = (down('ArrowRight') ? 1 : 0) - (down('ArrowLeft') ? 1 : 0);
    const dy = (down('ArrowUp') ? 1 : 0) - (down('ArrowDown') ? 1 : 0);
    if (dx || dy) amPending.push({ name: 'am_pan', params: [dx * 16, dy * 16] });
  }
  const up = arrowsPan ? down('KeyW') : down('KeyW', 'ArrowUp');
  const back = arrowsPan ? down('KeyS') : down('KeyS', 'ArrowDown');
  const right = arrowsPan ? down('KeyE') : down('KeyE', 'ArrowRight');
  const left = arrowsPan ? down('KeyQ') : down('KeyQ', 'ArrowLeft');
  const fwd = enabled ? (up ? 1 : 0) - (back ? 1 : 0) : 0;
  const strafe = enabled ? (down('KeyD') ? 1 : 0) - (down('KeyA') ? 1 : 0) : 0;
  const turnKeys = enabled ? (right ? 1 : 0) - (left ? 1 : 0) : 0;
  const turn = enabled ? turnKeys * TURN_DEGREES_PER_TIC + input.mouseTurn : 0;
  input.mouseTurn = 0;
  const run = enabled && down('ShiftLeft', 'ShiftRight');
  // While dead, fire or use is the request to respawn (P_DeathThink); the
  // server decides when. The press just has to reach it.
  const fire = down('ControlLeft', 'ControlRight') || input.fireHeld || (!alive && down('Space'));
  const use = input.pendingUse;
  input.pendingUse = false;
  const weapon = input.pendingWeapon;
  input.pendingWeapon = null;
  return [fwd, strafe, run, turn, fire, weapon, use];
}

// -------------------------------------------------------------------- audio
class Audio {
  constructor() {
    this.ctx = new (window.AudioContext || window.webkitAudioContext)();
    this.buffers = new Map();
    this.loops = new Map();
    this.music = null;
    this.musicName = null;
  }
  async load(rows) {
    await Promise.all(rows.map(async ([name, wav]) => {
      try {
        this.buffers.set(name, await this.ctx.decodeAudioData(wav.buffer.slice(wav.byteOffset, wav.byteOffset + wav.byteLength)));
      } catch (e) { console.warn('cannot decode', name, e); }
    }));
  }
  _chain(name, volume, pan, loop) {
    const buffer = this.buffers.get(name);
    if (!buffer) return null;
    const src = this.ctx.createBufferSource();
    src.buffer = buffer;
    src.loop = loop;
    const gain = this.ctx.createGain();
    gain.gain.value = volume;
    let node = gain;
    if (this.ctx.createStereoPanner) {
      const panner = this.ctx.createStereoPanner();
      panner.pan.value = pan;
      gain.connect(panner);
      node = panner;
    }
    src.connect(gain);
    node.connect(this.ctx.destination);
    src.start();
    return { src, gain };
  }
  play(name, volume, pan) { if (volume > 0) this._chain(name, volume, pan, false); }
  setLoops(rows) {
    const wanted = new Map(rows.map(([key, name, volume, pan]) => [key, { name, volume: +volume, pan: +pan }]));
    for (const [key, chain] of this.loops) {
      if (!wanted.has(key)) { try { chain.src.stop(); } catch (e) { /* already ended */ } this.loops.delete(key); }
    }
    for (const [key, { name, volume, pan }] of wanted) {
      const chain = this.loops.get(key);
      if (chain) chain.gain.gain.value = volume;
      else { const c = this._chain(name, volume, pan, true); if (c) this.loops.set(key, c); }
    }
  }
  stopAll() { for (const [, chain] of this.loops) { try { chain.src.stop(); } catch (e) { /* */ } } this.loops.clear(); }
  async setMusic(name, bytes) {
    if (this.musicName === name) return;
    this.stopMusic();
    this.musicName = name;
    if (!bytes || !bytes.byteLength) return;
    let buffer;
    try {
      buffer = await this.ctx.decodeAudioData(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    } catch (e) { console.warn('cannot decode music', name, e); return; }
    if (this.musicName !== name) return;           // the map changed while decoding
    const src = this.ctx.createBufferSource();
    src.buffer = buffer; src.loop = true;
    const gain = this.ctx.createGain();
    gain.gain.value = 0.35;
    src.connect(gain); gain.connect(this.ctx.destination);
    src.start();
    this.music = { src, gain };
  }
  stopMusic() {
    if (this.music) { try { this.music.src.stop(); } catch (e) { /* already ended */ } this.music = null; }
    this.musicName = null;
  }
}

// ----------------------------------------------------------------- palette
function buildPalette(rows) {
  const lut = new Uint32Array(14 * 256);           // ABGR for a little-endian Uint32 view of RGBA bytes
  for (const [pal, idx, r, g, b] of rows) {
    lut[(+pal) * 256 + (+idx)] = (255 << 24) | ((+b) << 16) | ((+g) << 8) | (+r);
  }
  for (let i = 0; i < lut.length; i++) if (lut[i] === 0) lut[i] = 0xff000000;
  return lut;
}

function blit(frame, lut) {
  const base = frame[0] * 256;
  for (let i = 0; i < W * H; i++) pixels[i] = lut[base + frame[1 + i]];
  ctx.putImageData(image, 0, 0);
}

// The automap comes back as RGB bytes, the same buffer the native client blits.
function blitRGB(rgb) {
  for (let i = 0, j = 0; i < W * H; i++, j += 3) pixels[i] = 0xff000000 | (rgb[j + 2] << 16) | (rgb[j + 1] << 8) | rgb[j];
  ctx.putImageData(image, 0, 0);
}

// -------------------------------------------------------------------- game
async function play(user, password, target, nick, guest) {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const url = `${proto}://${location.host}/pg?target=${encodeURIComponent(target)}${guest ? '&guest=1' : ''}`;
  pg = new PgConnection(url, ['pg-delta']);
  pg.onclose = (err) => { if (running) stop(`disconnected: ${err.message}`, true); };
  status(guest ? 'asking for a guest seat ...' : 'connecting ...');
  await pg.connect(guest ? { guest: true } : { user, password });
  user = pg.user;
  status(`signed in as ${user}; loading palettes and sounds ...`);
  try { await pg.query('SET async_commit = on'); } catch (e) { console.warn('async_commit not supported by this server:', e.message); }
  if (clientParallel) {
    // One renderer does not need the whole machine; see MULTIPLAYER.md.
    try { await pg.query(`SET max_parallel_workers = ${parseInt(clientParallel, 10)}`); } catch (e) { console.warn('max_parallel_workers not supported by this server:', e.message); }
  }

  await pg.prepare('palettes', 'SELECT pal, idx, r, g, b FROM api_palettes');
  await pg.prepare('sounds_all', 'SELECT name, wav_data FROM sound_assets');
  await pg.prepare('join', 'SELECT api_join()');
  await pg.prepare('slot', 'SELECT api_slot()');
  await pg.prepare('setname', 'SELECT api_set_name($1)', [OID.text]);
  await pg.prepare('score', 'SELECT slot, role_name, connected, frags, health, alive, login FROM api_scoreboard');
  await pg.prepare('match', 'SELECT state, map_name, level_tics, timer_tics, intermission_seconds, next_map, map_id, waiting, ahead_of_me, hold_seconds FROM api_match');
  await pg.prepare('me', 'SELECT alive, health, frags, position_x, position_y FROM api_player_state');
  await pg.prepare('automap', 'SELECT api_automap()', []);
  await pg.prepare('am_pan', 'SELECT api_automap_pan($1,$2)', [OID.float8, OID.float8]);
  await pg.prepare('am_zoom', 'SELECT api_automap_zoom($1)', [OID.float8]);
  await pg.prepare('am_toggle', 'SELECT api_automap_toggle($1)', [OID.text]);
  await pg.prepare('am_fit', 'SELECT api_automap_fit()', []);
  await pg.prepare('input', 'SELECT api_input($1,$2,$3,$4,$5,$6,$7)',
    [OID.float4, OID.float4, OID.bool, OID.float4, OID.bool, OID.int4, OID.bool]);
  await pg.prepare('camera', 'SELECT api_camera($1)', [OID.float8]);
  await pg.prepare('events', 'SELECT event_id, sound_name, volume, pan FROM api_sound_events WHERE event_id > $1 ORDER BY event_id', [OID.int8]);
  await pg.prepare('events_max', 'SELECT COALESCE(MAX(event_id), 0) FROM api_sound_events');
  await pg.prepare('loops', 'SELECT loop_key, sound_name, volume, pan FROM api_sound_loops');
  await pg.prepare('music', 'SELECT name, audio_data, audio_format FROM api_stage_music');
  await pg.prepare('weapon_slot', 'SELECT api_weapon_slot($1)', [OID.int4]);
  await pg.prepare('weapon_cycle', 'SELECT api_weapon_cycle($1)', [OID.int4]);
  await pg.prepare('map_geo', 'SELECT x1, y1, x2, y2, solid FROM api_map_geometry');
  await pg.prepare('live', 'SELECT kind, name, x, y, angle, alive FROM api_things_live WHERE map_id = $1', [OID.int4]);

  const [pal, snd] = await pg.run([{ name: 'palettes' }, { name: 'sounds_all', binary: true }]);
  const lut = buildPalette(pal.rows);
  audio = new Audio();
  await audio.load(snd.rows.map(([name, wav]) => [new TextDecoder().decode(name), wav]));

  // The lobby: claim a slot, or wait for one to free up.
  let announced = null;   // which of the two waits was last said, so a change is said again
  // The level outline for the map being played, fetched once per map. Waiting
  // used to be a grey panel; this is the match, live, while you queue.
  const lobbyMap = { mapId: -1, lines: [], bounds: null };
  const lobbyCtx = ui.lobbyMap.getContext('2d', { alpha: false });
  // The cloud console draws this same plan view in SVG while you are idle
  // (DoomTab.tsx, MapOverview) and hands over to this one the moment you
  // queue, so the two share a palette: one-sided walls bone, two-sided dim
  // red, monsters red, a player an arrow in its own colour.
  const WALL_SOLID = '#efe6d8', WALL_OPEN = '#6e2a25', MONSTER = '#c2352c';
  const PLAYER_COLOURS = ['#4fbf4f', '#7b7bff', '#c48a4a', '#ff5a4a'];

  async function drawLobby(mapId, mapName) {
    if (mapId === undefined || mapId === null || mapId < 0) return;
    if (lobbyMap.mapId !== mapId) {
      const [geo] = await pg.run([{ name: 'map_geo' }]);
      if (!geo.rows.length) return;            // between maps: keep the last outline
      lobbyMap.lines = geo.rows.map(([x1, y1, x2, y2, solid]) =>
        [parseFloat(x1), parseFloat(y1), parseFloat(x2), parseFloat(y2), solid === 't' || solid === true]);
      const xs = lobbyMap.lines.flatMap((l) => [l[0], l[2]]);
      const ys = lobbyMap.lines.flatMap((l) => [l[1], l[3]]);
      lobbyMap.bounds = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
      lobbyMap.mapId = mapId;
    }
    if (!lobbyMap.bounds) return;
    const [things] = await pg.run([{ name: 'live', params: [mapId] }]);

    // Its own backing store at the element's real size: the game canvas is
    // 320x200 upscaled, and a plan view drawn there would go blocky exactly
    // where the console's SVG is crisp.
    const dpr = window.devicePixelRatio || 1;
    const cw = Math.max(1, Math.round(ui.lobbyMap.clientWidth * dpr));
    const ch = Math.max(1, Math.round(ui.lobbyMap.clientHeight * dpr));
    if (ui.lobbyMap.width !== cw || ui.lobbyMap.height !== ch) {
      ui.lobbyMap.width = cw; ui.lobbyMap.height = ch;
    }
    // The console's viewBox: 64 map units of margin, fitted xMidYMid meet.
    const pad = 64;
    const [minX, minY, maxX, maxY] = lobbyMap.bounds;
    const vw = maxX - minX + 2 * pad, vh = maxY - minY + 2 * pad;
    const scale = Math.min(cw / vw, ch / vh);
    const offX = (cw - vw * scale) / 2, offY = (ch - vh * scale) / 2;
    // Map y grows northwards, canvas y downwards.
    const sx = (x) => offX + (x - (minX - pad)) * scale;
    const sy = (y) => offY + ((maxY + pad) - y) * scale;
    const r = (Math.max(vw, vh) / 90) * scale;          // marker radius, in pixels
    const font = (Math.max(vw, vh) / 45) * scale;

    ui.lobbyMap.hidden = false;
    ui.overlay.classList.add('queue');   // the notice steps out of the way
    lobbyCtx.fillStyle = '#000';
    lobbyCtx.fillRect(0, 0, cw, ch);
    for (const [x1, y1, x2, y2, solid] of lobbyMap.lines) {
      lobbyCtx.strokeStyle = solid ? WALL_SOLID : WALL_OPEN;
      lobbyCtx.lineWidth = (solid ? 1.2 : 1) * dpr;     // the console's non-scaling stroke
      lobbyCtx.beginPath();
      lobbyCtx.moveTo(sx(x1), sy(y1));
      lobbyCtx.lineTo(sx(x2), sy(y2));
      lobbyCtx.stroke();
    }
    let playerIndex = 0;
    for (const [kind, name, x, y, angle, alive] of things.rows) {
      const px = sx(parseFloat(x)), py = sy(parseFloat(y));
      const up = alive === 't' || alive === true;
      if (kind === 'monster') {
        if (!up) continue;
        lobbyCtx.fillStyle = MONSTER;
        lobbyCtx.strokeStyle = '#000';
        lobbyCtx.lineWidth = 0.5 * dpr;
        lobbyCtx.beginPath();
        lobbyCtx.arc(px, py, r * 0.7, 0, Math.PI * 2);
        lobbyCtx.fill(); lobbyCtx.stroke();
        continue;
      }
      // A player: the console's arrow, pointing where they face.
      const colour = PLAYER_COLOURS[playerIndex++ % PLAYER_COLOURS.length];
      const rad = (parseFloat(angle) * Math.PI) / 180;
      lobbyCtx.globalAlpha = up ? 1 : 0.45;
      lobbyCtx.fillStyle = colour;
      lobbyCtx.strokeStyle = '#000';
      lobbyCtx.lineWidth = (r / 6) * dpr;
      lobbyCtx.beginPath();
      lobbyCtx.moveTo(px + Math.cos(rad) * r * 2.2, py - Math.sin(rad) * r * 2.2);
      lobbyCtx.lineTo(px + Math.cos(rad + 2.4) * r * 1.3, py - Math.sin(rad + 2.4) * r * 1.3);
      lobbyCtx.lineTo(px + Math.cos(rad - 2.4) * r * 1.3, py - Math.sin(rad - 2.4) * r * 1.3);
      lobbyCtx.closePath();
      lobbyCtx.fill(); lobbyCtx.stroke();
      if (name) {
        lobbyCtx.font = `600 ${font}px ui-monospace, monospace`;
        lobbyCtx.textAlign = 'center';
        lobbyCtx.lineWidth = font * 0.35;
        lobbyCtx.strokeStyle = '#000';
        lobbyCtx.strokeText(name, px, py - r * 3);
        lobbyCtx.fillText(name, px, py - r * 3);
      }
      lobbyCtx.globalAlpha = 1;
    }
    // The console's caption, same place, same words.
    const players = things.rows.filter((t) => t[0] === 'player').length;
    const monsters = things.rows.filter((t) => t[0] === 'monster').length;
    lobbyCtx.font = `${font * 0.9}px ui-monospace, monospace`;
    lobbyCtx.textAlign = 'left';
    lobbyCtx.fillStyle = '#c9a99c';
    lobbyCtx.fillText(`${mapName || ''} · ${players} ${players === 1 ? 'player' : 'players'}, ${monsters} monsters`,
      offX + font, offY + font * 1.4);
  }
  for (;;) {
    let j, s, m;
    try {
      [j, s, m] = await pg.run([{ name: 'join' }, { name: 'score' }, { name: 'match' }]);
    } catch (err) {
      // Two joins racing for one slot, or the referee handing a slot back at
      // the same moment: CedarDB reports a serialization failure. Try again.
      if (err.code === '40001' || /concurrent/i.test(err.message)) { await sleep(200); continue; }
      throw err;
    }
    renderScore(s.rows, user);
    if (parseInt(j.rows[0][0], 10) >= 0) break;
    const between = m.rows[0] && m.rows[0][0] !== 'playing';
    const waiting = m.rows[0] ? parseInt(m.rows[0][7], 10) : 0;
    const ahead = m.rows[0] && m.rows[0][8] !== null ? parseInt(m.rows[0][8], 10) : 0;
    if (announced !== between) { status(between ? 'the match is between maps; joining when the next one starts ...' : 'all four slots are taken; you are in the queue, first come first served ...'); announced = between; }
    ui.overlay.hidden = false;
    ui.overlayText.textContent = between ? `BETWEEN MAPS — ${m.rows[0][5]} IS NEXT`
      : (ahead > 0 ? `WAITING FOR A SLOT — ${ahead} AHEAD OF YOU` : 'WAITING FOR A SLOT — YOU ARE NEXT')
        + (waiting > 1 ? `\n${waiting} WAITING` : '');
    inLobby = true; refreshScore();
    post('state', { state: 'lobby' });
    // A failed draw must not cost anyone their place in the queue: the join
    // heartbeat above is what holds it.
    try {
      await drawLobby(m.rows[0] ? parseInt(m.rows[0][6], 10) : -1, m.rows[0] ? m.rows[0][1] : '');
    } catch (e) {
      console.warn('lobby view unavailable:', e.message);
    }
    await sleep(1000);
  }
  inLobby = false; refreshScore();
  ui.lobbyMap.hidden = true;
  ui.overlay.classList.remove('queue');   // the intermission notice wants the middle back
  if (nick) { try { await pg.run([{ name: 'setname', params: [nick] }]); } catch (e) { console.warn('name not set:', e.message); } }
  const [s] = await pg.run([{ name: 'slot' }]);
  const slot = parseInt(s.rows[0][0], 10);
  // The frame view is rebuilt by the referee on every map change, so the
  // statement over it is prepared under a fresh name each time it is needed.
  // One frame view per slot and map (api_frame_idx_slot<n>_m<map>); the
  // statement over it is prepared under a fresh name whenever the map changes.
  let frameGen = 0, frameName = '', frameMap = -1;
  const match = { state: 'playing', map: '', mapId: -1, left: 0, next: '', seconds: 0, waiting: 0, hold: 0 };
  const joinedAt = performance.now();
  const prepareFrame = async () => {
    frameName = `frame${++frameGen}`; frameMap = match.mapId;
    await pg.prepare(frameName, `SELECT frame_rgb FROM api_frame_idx_slot${slot}_m${match.mapId}`);
  };
  const readMatch = (row) => {
    if (!row) return;
    const was = match.map;
    match.state = row[0]; match.map = row[1]; match.mapId = parseInt(row[6], 10);
    const timer = parseInt(row[3], 10);
    match.left = timer > 0 ? Math.max(0, Math.round((timer - parseInt(row[2], 10)) / 35)) : -1;
    match.seconds = parseInt(row[4], 10); match.next = row[5];
    match.waiting = parseInt(row[7], 10) || 0; match.hold = parseInt(row[9], 10) || 0;
    intermission = match.state === 'intermission'; refreshScore();
    if (intermission) {
      ui.overlay.hidden = false;
      ui.overlayText.textContent = `${match.map} COMPLETE — ${match.next} IN ${match.seconds} s`;
    }
    if (was && match.map !== was) status(`now on ${match.map}, slot ${slot}`);
    if (match.map !== was) loadMusic();
  };
  const loadMusic = async () => {
    if (!audio) return;
    try {
      const [m] = await pg.run([{ name: 'music', binary: true }]);
      const row = m.rows[0];
      if (!row) { audio.stopMusic(); return; }
      await audio.setMusic(new TextDecoder().decode(row[0]), row[1]);
    } catch (e) { console.warn('music unavailable', e); }
  };
  readMatch((await pg.run([{ name: 'match' }]))[0].rows[0]);
  await prepareFrame();
  ui.overlay.hidden = true;
  status(`in the game as ${user}, slot ${slot}. Click the screen to grab the mouse.`);
  ui.help.hidden = false;

  running = true;
  ui.stage.classList.add('live');
  ui.stage.focus();
  post('state', { state: 'playing', user, slot });
  const stats = { frames: 0, bytes: 0, rtt: 0, tics: 0, ticRtt: 0, since: performance.now(), alive: true, health: 100, frags: 0, x: 0, y: 0 };
  // Bytes on the wire come from the relay once a second (pgwire.js onwire);
  // the difference between two reports is this second's egress.
  let wireAt = performance.now(), wireBytes = pg.wire ? pg.wire.wire_out : 0, wireKbps = null;
  pg.onwire = (w) => {
    const now = performance.now();
    if (now - wireAt >= 500) wireKbps = (w.wire_out - wireBytes) / ((now - wireAt) / 1000);
    wireAt = now; wireBytes = w.wire_out;
  };
  let lastEvent = parseInt((await pg.run([{ name: 'events_max' }]))[0].rows[0][0], 10);
  let lastTic = performance.now();
  let ticInFlight = 0;

  // 35 Hz: input out, sounds and my own state back, one round trip.
  const ticker = setInterval(async () => {
    if (!running || ticInFlight > 2) return;
    ticInFlight++;
    try {
      if (input.weaponKey !== null) {
        const k = input.weaponKey; input.weaponKey = null;
        const [w] = await pg.run([{ name: 'weapon_slot', params: [k] }]);
        const id = parseInt(w.rows[0][0], 10);
        if (id >= 0) input.pendingWeapon = id;
      }
      if (input.wheel !== 0) {
        const step = Math.sign(input.wheel); input.wheel = 0;
        const [w] = await pg.run([{ name: 'weapon_cycle', params: [step] }]);
        const id = parseInt(w.rows[0][0], 10);
        if (id >= 0) input.pendingWeapon = id;
      }
      const command = readCommand(stats.alive);
      lastTic = performance.now();
      const [, me, ev, lp] = await pg.run([
        { name: 'input', params: command },
        { name: 'me' },
        { name: 'events', params: [lastEvent] },
        { name: 'loops' },
      ]);
      // The tic's latency as the player feels it: input out, own state back.
      stats.ticRtt += performance.now() - lastTic; stats.tics++;
      if (me.rows.length) {
        stats.alive = me.rows[0][0] === 't';
        stats.health = parseInt(me.rows[0][1], 10);
        stats.frags = parseInt(me.rows[0][2], 10);
        stats.x = parseFloat(me.rows[0][3]); stats.y = parseFloat(me.rows[0][4]);
        dead = !stats.alive; refreshScore();
      }
      for (const [id, name, volume, pan] of ev.rows) {
        lastEvent = Math.max(lastEvent, parseInt(id, 10));
        audio.play(name, +volume, +pan);
      }
      audio.setLoops(lp.rows);
      if (!intermission) {
        ui.overlay.hidden = stats.alive;
        if (!stats.alive) ui.overlayText.textContent = 'YOU DIED — FIRE OR SPACE TO RESPAWN';
      }
    } catch (err) {
      if (running) console.warn('tic dropped:', err.message);
    } finally {
      ticInFlight--;
    }
  }, TIC_MS);

  // Frames: as fast as the database answers. Two requests stay in flight so
  // the network round trip overlaps the render; the connection answers them
  // in order, so each arrival is the newest frame. Deeper did not help: the
  // server works one connection's frames sequentially, so a third request
  // only waited in line and added its wait to the latency. api_camera doubles as the
  // heartbeat that keeps the slot ours.
  // One schedule shared by the in-flight requests: the next frame may be
  // asked for no sooner than 1000/maxFps after the previous one was.
  let nextFrameAt = performance.now();
  const pace = async () => {
    if (!maxFps) return;
    const interval = 1000 / maxFps;
    const now = performance.now();
    const at = Math.max(now, nextFrameAt);
    nextFrameAt = at + interval;
    if (at > now) await sleep(at - now);
  };
  const frameLoop = async () => {
    while (running) {
      await pace();
      if (!running) return;
      const alpha = Math.min(1, Math.max(0, (performance.now() - lastTic) / TIC_MS));
      const t0 = performance.now();
      let result;
      const mapUp = automap.on;
      try {
        if (mapUp) {
          // api_camera rides along as the heartbeat that keeps the slot ours,
          // and any view changes go in the same round trip as the frame.
          const pending = amPending.splice(0, amPending.length);
          result = await pg.run([{ name: 'camera', params: [alpha] }, ...pending,
            { name: 'automap', binary: true, params: [] }]);
        } else {
          result = await pg.run([{ name: 'camera', params: [alpha] }, { name: frameName, binary: true }]);
        }
      } catch (err) {
        if (!running) return;
        console.warn('frame dropped:', err.message);
        await sleep(50);
        continue;
      }
      const frame = result[1].rows[0] && result[1].rows[0][0];
      if (!frame) {
        // Either the slot was handed back, or the match moved to another map
        // and the view for this slot was rebuilt: ask which.
        let held = -1;
        try {
          const [sl, m] = await pg.run([{ name: 'slot' }, { name: 'match' }]);
          held = parseInt(sl.rows[0][0], 10); readMatch(m.rows[0]);
        } catch (e) { /* ask again */ }
        if (held !== slot) {
          // Either the referee reaped an idle seat, or the fair-play limit
          // came up while others were waiting (api_match says both).
          const held_for = (performance.now() - joinedAt) / 1000;
          const turn = match.hold > 0 && match.waiting > 0 && held_for >= match.hold - 5;
          stop(turn ? `your ${Math.round(match.hold / 60)} minutes are up and someone is waiting; press Play to queue again`
                    : 'the server took the slot back (idle too long?)', !turn);
          return;
        }
        if (frameMap !== match.mapId) {
          try { await prepareFrame(); } catch (e) { console.warn('frame view not ready yet:', e.message); }
        }
        await sleep(100);
        continue;
      }
      if (mapUp) blitRGB(frame); else blit(frame, lut);
      stats.frames++; stats.bytes += frame.length; stats.rtt += performance.now() - t0;
      const elapsed = performance.now() - stats.since;
      if (elapsed >= 1000) {
        const clock = match.left >= 0 ? ` · ${match.map} ${Math.floor(match.left / 60)}:${String(match.left % 60).padStart(2, '0')} left` : ` · ${match.map}`;
        const ticMs = stats.tics ? stats.ticRtt / stats.tics : 0;
        const wire = wireKbps === null ? '' : ` → ${(wireKbps / 1024).toFixed(0)} KB/s on the wire`;
        ui.stats.textContent = `${(stats.frames * 1000 / elapsed).toFixed(1)} fps · `
          + `${(stats.rtt / stats.frames).toFixed(1)} ms/frame · ${ticMs.toFixed(0)} ms/tic · `
          + `${(stats.bytes / elapsed).toFixed(0)} KB/s before ${pg.delta ? 'delta+deflate' : 'deflate'}${wire} · `
          + `${stats.frags} frags · ${stats.health} hp${clock}`;
        // The host draws these itself (fps large, the rest small); the map
        // and the clock it already has from the spectator's SQL.
        post('stats', {
          text: ui.stats.textContent,
          fps: stats.frames * 1000 / elapsed,
          msPerFrame: stats.rtt / stats.frames,
          ticMs,
          kbps: stats.bytes / elapsed,
          wireKbps: wireKbps === null ? null : wireKbps / 1024,
          frags: stats.frags,
          health: stats.health,
          coding: pg.delta ? 'delta+deflate' : 'deflate',
        });
        stats.frames = 0; stats.bytes = 0; stats.rtt = 0; stats.tics = 0; stats.ticRtt = 0; stats.since = performance.now();
        pg.run([{ name: 'score' }, { name: 'match' }]).then(([sc, m]) => { renderScore(sc.rows, user); readMatch(m.rows[0]); }).catch(() => {});
      }
    }
  };
  for (let i = 0; i < FRAMES_IN_FLIGHT; i++) frameLoop();

  const stop = (why, bad) => {
    if (!running) return;
    running = false;
    clearInterval(ticker);
    if (audio) { audio.stopAll(); audio.stopMusic(); }
    if (document.pointerLockElement) document.exitPointerLock();
    ui.stage.classList.remove('live');
    ui.overlay.hidden = true;
    ui.help.hidden = true;
    ui.button.disabled = false;
    status(why, bad);
    post('state', { state: 'stopped' });
    try { pg.close(); } catch (e) { /* */ }
  };
  window.doomStop = stop;
  // A tab in the background would keep pulling frames nobody sees and hold a
  // seat someone else could have. Leave instead; Play brings you back.
  const onVisibility = () => {
    if (document.hidden && running) {
      document.removeEventListener('visibilitychange', onVisibility);
      stop('left the game: the tab went to the background', false);
    }
  };
  document.addEventListener('visibilitychange', onVisibility);
}

function renderScore(rows, me) {
  const ordered = [...rows].sort((a, b) => parseInt(a[0], 10) - parseInt(b[0], 10));
  ui.score.innerHTML = '<h2>DEATHMATCH</h2>' + ordered.map(([slot, role, connected, frags, health, alive, login]) => {
    const who = connected === 't' ? role : '<em>free</em>';
    const you = login === me ? ' (you)' : '';
    const state = connected === 't' ? `${frags} frags · ${health} hp${alive === 't' ? '' : ' · dead'}` : '';
    return `<div class="row"><span class="slot">${slot}</span><span class="who">${who}${you}</span><span class="state">${state}</span></div>`;
  }).join('');
}

// ------------------------------------------------------------------- setup
async function setup() {
  try {
    const cfg = await (await fetch('config.json')).json();
    ui.target.innerHTML = cfg.targets.map((t) => `<option value="${t}">${t}</option>`).join('');
    // One server to pick from is no choice; show the field only when there are several.
    ui.targetField.hidden = cfg.targets.length < 2;
    clientParallel = cfg.parallel || null;
    guestSeats = cfg.guests || 0;
    if (typeof cfg.max_fps === 'number') maxFps = Math.max(0, cfg.max_fps);
  } catch (e) {
    ui.target.innerHTML = '<option value="127.0.0.1:5720">127.0.0.1:5720</option>';
  }
  // Without guest seats the page is the account form; with them the account
  // form hides behind a link.
  const showAccount = (on) => {
    accountMode = on;
    ui.userField.hidden = !on; ui.passwordField.hidden = !on;
    ui.user.required = on; ui.password.required = on;
    ui.button.textContent = on ? 'JOIN' : 'PLAY';
    ui.accountToggle.textContent = on ? 'play as a guest instead' : 'sign in with a player account';
    ui.accountToggle.hidden = guestSeats === 0;
  };
  showAccount(guestSeats === 0);
  ui.accountToggle.addEventListener('click', (ev) => { ev.preventDefault(); showAccount(!accountMode); });
  const params = new URLSearchParams(location.search);
  if (params.get('user')) ui.user.value = params.get('user');
  if (params.get('target')) ui.target.value = params.get('target');
  if (params.get('nick')) ui.nick.value = params.get('nick').slice(0, 12);
  const start = async (user, password, nick, guest) => {
    ui.button.disabled = true;
    post('state', { state: 'connecting' });
    try {
      await play(user, password, ui.target.value, nick, guest);
    } catch (err) {
      running = false;
      ui.button.disabled = false;
      status(`could not join: ${err.message}`, true);
      post('state', { state: 'stopped' });
      if (pg) { try { pg.close(); } catch (e) { /* */ } }
    }
  };
  ui.form.addEventListener('submit', (ev) => {
    ev.preventDefault();
    start(ui.user.value.trim(), ui.password.value, ui.nick.value.trim(), !accountMode);
  });
  // Embedded in another page (?embed=1 inside an iframe): the page is just
  // the screen. The host draws the form and asks us to play or stop; we tell
  // it what the status and stats lines would have said.
  embedded = params.get('embed') === '1' && window.parent !== window;
  if (embedded) {
    document.body.classList.add('embed');
    window.addEventListener('message', (ev) => {
      const m = ev.data;
      if (!m || m.source !== 'sqldoom-host') return;
      if (m.action === 'play' && !running && !ui.button.disabled) {
        const nick = String(m.nick || '').slice(0, 12).trim();
        if (m.user) start(String(m.user), String(m.password || ''), nick, false);
        else start('', '', nick, true);
      }
      if (m.action === 'stop' && window.doomStop) window.doomStop('left the game', false);
    });
    post('ready', { guests: guestSeats, targets: ui.target.options.length });
  }
}

setup();
