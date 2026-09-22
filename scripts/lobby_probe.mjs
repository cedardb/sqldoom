#!/usr/bin/env node
// Join as a guest and report the lobby queue for a few seconds: what api_join
// says and what api_match shows as waiting / ahead_of_me.
//   node --experimental-websocket scripts/lobby_probe.mjs ws://host/pg [seconds] [name]
import { PgConnection } from '../web/pgwire.js';
const [url, secondsArg, name] = process.argv.slice(2);
const pg = new PgConnection(`${url}?guest=1`, ['pg-delta']);
await pg.connect({ guest: true });
await pg.prepare('join', 'SELECT api_join()');
await pg.prepare('match', 'SELECT state, waiting, ahead_of_me FROM api_match');
const t0 = Date.now();
while (Date.now() - t0 < parseFloat(secondsArg || '6') * 1000) {
  const [j, m] = await pg.run([{ name: 'join' }, { name: 'match' }]);
  console.log(`${name || pg.user} t+${((Date.now() - t0) / 1000).toFixed(0)}s join=${j.rows[0][0]} state=${m.rows[0][0]} waiting=${m.rows[0][1]} ahead_of_me=${m.rows[0][2]} delta=${pg.delta}`);
  await new Promise((r) => setTimeout(r, 1000));
}
pg.close();
