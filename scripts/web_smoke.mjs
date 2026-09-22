#!/usr/bin/env node
// Drive the browser client's database path from Node: through doom_web.py's
// tunnel, sign in as a player role with the same pgwire.js the page uses,
// claim a slot, and pull camera+frame pairs for a few seconds.
//
//   node scripts/web_smoke.mjs ws://127.0.0.1:8080/pg doom_player1 '<password>' [seconds] [target]
import { PgConnection, OID } from '../web/pgwire.js';

const [url, user, password, secondsArg, target] = process.argv.slice(2);
if (!url || !user || password === undefined) {
  console.error('usage: web_smoke.mjs <ws url> <user> <password> [seconds] [target host:port]');
  process.exit(2);
}
const seconds = parseFloat(secondsArg || '5');
// DOOM_NO_DELTA=1 measures the wire without delta frames, for comparison
const pg = new PgConnection(target ? `${url}?target=${encodeURIComponent(target)}` : url, process.env.DOOM_NO_DELTA ? [] : ['pg-delta']);
pg.onclose = (err) => { if (!done) { console.error('closed early:', err.message); process.exit(1); } };
let done = false;

try {
  await pg.connect({ user, password });
} catch (err) {
  console.error(`sign-in failed: ${err.message}`);
  process.exit(1);
}
console.log(`signed in as ${user} (server ${pg.parameters.server_version || '?'})`);
await pg.prepare('join', 'SELECT api_join()');
await pg.prepare('slot', 'SELECT api_slot()');
await pg.prepare('camera', 'SELECT api_camera($1)', [OID.float8]);
await pg.prepare('input', 'SELECT api_input($1,$2,$3,$4,$5,$6,$7)',
  [OID.float4, OID.float4, OID.bool, OID.float4, OID.bool, OID.int4, OID.bool]);
await pg.prepare('palettes', 'SELECT count(*) FROM api_palettes');
await pg.prepare('sounds', 'SELECT name, wav_data FROM sound_assets');

let thing = -1;
for (let i = 0; i < 30 && thing < 0; i++) {
  try {
    thing = parseInt((await pg.run([{ name: 'join' }]))[0].rows[0][0], 10);
  } catch (err) {
    // two joins racing for one slot: one fails to serialize and asks again, as the page does
    if (err.code !== '40001' && !/concurrent/i.test(err.message)) throw err;
  }
  if (thing < 0) await new Promise((r) => setTimeout(r, 1000));
}
if (thing < 0) { console.error('no free slot'); process.exit(1); }
const slot = parseInt((await pg.run([{ name: 'slot' }]))[0].rows[0][0], 10);
console.log(`joined: thing ${thing}, slot ${slot}`);
const [pal, snd] = await pg.run([{ name: 'palettes' }, { name: 'sounds', binary: true }]);
console.log(`palette rows ${pal.rows[0][0]}, sounds ${snd.rows.length} (${snd.rows.reduce((n, r) => n + r[1].length, 0)} bytes)`);
await pg.prepare('match', 'SELECT map_id FROM api_match');
const mapId = (await pg.run([{ name: 'match' }]))[0].rows[0][0];
await pg.prepare('frame', `SELECT frame_rgb FROM api_frame_idx_slot${slot}_m${mapId}`);

let frames = 0, bytes = 0, first = null, rtt = 0;
const t0 = performance.now();
const ticker = setInterval(() => {
  // DOOM_STILL=1: stand still and do nothing, the other bound of the frame stream
  pg.run([{ name: 'input', params: process.env.DOOM_STILL ? [0, 0, false, 0, false, null, false] : [1, 0, false, 2.0, frames % 20 === 0, null, false] }]).catch(() => {});
}, 1000 / 35);
while (performance.now() - t0 < seconds * 1000) {
  const f0 = performance.now();
  const [, fr] = await pg.run([{ name: 'camera', params: [0.5] }, { name: 'frame', binary: true }]);
  rtt += performance.now() - f0;
  const frame = fr.rows[0][0];
  if (!frame) { console.error('empty frame: slot lost'); process.exit(1); }
  if (first === null) first = frame;
  frames++; bytes += frame.length;
}
clearInterval(ticker);
const elapsed = (performance.now() - t0) / 1000;
const distinct = new Set(first.subarray(1)).size;
console.log(`${frames} frames in ${elapsed.toFixed(1)} s = ${(frames / elapsed).toFixed(1)} fps, ${(rtt / frames).toFixed(1)} ms per camera+frame round trip; `
  + `${(bytes / frames).toFixed(0)} bytes/frame (palette byte ${first[0]}, ${distinct} distinct indices in the first frame)`);
done = true;
pg.close();
process.exit(frames > 0 && distinct > 8 ? 0 : 1);
