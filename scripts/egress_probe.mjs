#!/usr/bin/env node
// What a player costs on the wire, and what each coding would save. Joins the
// match as a guest through the relay *without* the pg-delta subprotocol, so
// the frames arrive raw, plays for a few seconds the way the bots do (walk,
// turn, fire now and then), keeps every frame, and then codes the sequence
// several ways with Node's zlib:
//
//   raw                 64 001 bytes a frame, what the database sends
//   deflate6            each frame alone, level 6
//   shared6             one deflate context across frames, Z_SYNC_FLUSH per frame
//   xor+shared6         XOR against the previous frame, then shared6  (the relay today)
//   xor+shared9         the same at level 9
//   dict6               each frame alone, level 6, previous frame as the dictionary
//
// and prints bytes per frame, per second at the measured rate, and per hour
// at 35 fps, which is what an egress bill is made of.
//
//   node scripts/egress_probe.mjs ws://127.0.0.1:8090/pg [seconds]
import zlib from 'node:zlib';
import { PgConnection, OID } from '../web/pgwire.js';

const [url, secondsArg] = process.argv.slice(2);
if (!url) { console.error('usage: egress_probe.mjs <ws url> [seconds]'); process.exit(2); }
const seconds = parseFloat(secondsArg || '10');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const pg = new PgConnection(url + '?guest=1', []);          // no pg-delta: raw frames
let done = false;
pg.onclose = (err) => { if (!done) { console.error('closed early:', err.message); process.exit(1); } };
await pg.connect({ guest: true });
console.log(`signed in as ${pg.user}`);
await pg.prepare('join', 'SELECT api_join()');
await pg.prepare('slot', 'SELECT api_slot()');
await pg.prepare('camera', 'SELECT api_camera($1)', [OID.float8]);
await pg.prepare('input', 'SELECT api_input($1,$2,$3,$4,$5,$6,$7)',
  [OID.float4, OID.float4, OID.bool, OID.float4, OID.bool, OID.int4, OID.bool]);
await pg.prepare('match', 'SELECT map_id FROM api_match');
let thing = -1;
for (let i = 0; i < 30 && thing < 0; i++) {
  try { thing = parseInt((await pg.run([{ name: 'join' }]))[0].rows[0][0], 10); }
  catch (err) { if (err.code !== '40001' && !/concurrent/i.test(err.message)) throw err; }
  if (thing < 0) await sleep(1000);
}
if (thing < 0) { console.error('no free slot'); process.exit(1); }
const slot = parseInt((await pg.run([{ name: 'slot' }]))[0].rows[0][0], 10);
const mapId = (await pg.run([{ name: 'match' }]))[0].rows[0][0];
await pg.prepare('frame', `SELECT frame_rgb FROM api_frame_idx_slot${slot}_m${mapId}`);
console.log(`slot ${slot} on map ${mapId}; recording ${seconds} s of frames while walking and turning`);

const frames = [];
const t0 = performance.now();
const ticker = setInterval(() => {
  pg.run([{ name: 'input', params: [1, 0, false, 2.0, frames.length % 20 === 0, null, false] }]).catch(() => {});
}, 1000 / 35);
while (performance.now() - t0 < seconds * 1000) {
  const [, fr] = await pg.run([{ name: 'camera', params: [0.5] }, { name: 'frame', binary: true }]);
  const frame = fr.rows[0][0];
  if (!frame) { console.error('empty frame: slot lost'); process.exit(1); }
  frames.push(Buffer.from(frame));
}
clearInterval(ticker);
const elapsed = (performance.now() - t0) / 1000;
done = true;
pg.close();
const fps = frames.length / elapsed;
console.log(`${frames.length} frames in ${elapsed.toFixed(1)} s = ${fps.toFixed(1)} fps\n`);

// --- the codings -----------------------------------------------------------
function xor(a, b) { const out = Buffer.alloc(a.length); for (let i = 0; i < a.length; i++) out[i] = a[i] ^ (b[i] ?? 0); return out; }
function perFrame(level, dictOfPrevious) {
  let total = 0;
  frames.forEach((f, i) => {
    const opts = { level };
    if (dictOfPrevious && i > 0) opts.dictionary = frames[i - 1];
    total += zlib.deflateRawSync(f, opts).length;
  });
  return total;
}
function shared(level, delta) {
  const z = zlib.createDeflateRaw({ level });
  let total = 0;
  z.on('data', (chunk) => { total += chunk.length; });
  return new Promise((resolve) => {
    let i = 0;
    const step = () => {
      if (i >= frames.length) { z.end(); return; }
      const f = delta && i > 0 ? xor(frames[i], frames[i - 1]) : frames[i];
      i++;
      z.write(f, () => z.flush(zlib.constants.Z_SYNC_FLUSH, step));
    };
    z.on('end', () => resolve(total));
    step();
  });
}
const raw = frames.reduce((n, f) => n + f.length, 0);
const rows = [
  ['raw', raw],
  ['deflate6 (each frame alone)', perFrame(6, false)],
  ['shared6 (one context, sync flush)', await shared(6, false)],
  ['xor+shared6 (the relay today)', await shared(6, true)],
  ['xor+shared9', await shared(9, true)],
  ['dict6 (previous frame as dictionary)', perFrame(6, true)],
];
const pad = (s, n) => String(s).padStart(n);
console.log(`${'coding'.padEnd(38)} ${pad('bytes/frame', 12)} ${pad('KB/s @' + fps.toFixed(0) + 'fps', 14)} ${pad('GB/h @35fps', 12)} ${pad('vs raw', 8)}`);
for (const [name, bytes] of rows) {
  const perF = bytes / frames.length;
  console.log(`${name.padEnd(38)} ${pad(perF.toFixed(0), 12)} ${pad((perF * fps / 1024).toFixed(0), 14)} ${pad((perF * 35 * 3600 / 1e9).toFixed(2), 12)} ${pad((raw / bytes).toFixed(1) + 'x', 8)}`);
}
process.exit(0);
