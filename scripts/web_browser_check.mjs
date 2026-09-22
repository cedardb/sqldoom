#!/usr/bin/env node
// Drive the browser client in headless Chrome over the DevTools protocol:
// open the page, sign in as a player, hold W and turn, then report the page's
// own stats line, any console errors, and save a screenshot.
//
//   node scripts/web_browser_check.mjs http://127.0.0.1:8080/ doom_player1 '<password>' [seconds] [screenshot.png]
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [pageUrl, user, password, secondsArg, shot] = process.argv.slice(2);
if (!pageUrl || !user || password === undefined) { console.error('usage: web_browser_check.mjs <page url> <user> <password> [seconds] [png]'); process.exit(2); }
const seconds = parseFloat(secondsArg || '8');
const port = 9333 + Math.floor(Math.random() * 100);
const profile = mkdtempSync(join(tmpdir(), 'doom-chrome-'));
const chrome = spawn('google-chrome', ['--headless=new', `--remote-debugging-port=${port}`, '--no-sandbox', '--disable-gpu',
  '--autoplay-policy=no-user-gesture-required', `--user-data-dir=${profile}`, '--window-size=1300,900', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target = null;
for (let i = 0; i < 50 && !target; i++) {
  try { const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); target = list.find((t) => t.type === 'page'); } catch (e) { await sleep(200); }
}
if (!target) { console.error('chrome did not come up'); chrome.kill(); process.exit(1); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => { ws.onopen = r; });
let id = 0; const waiting = new Map(); const errors = [];
ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && waiting.has(msg.id)) { waiting.get(msg.id)(msg); waiting.delete(msg.id); }
  if (msg.method === 'Runtime.exceptionThrown') errors.push('exception: ' + (msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text));
  if (msg.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(msg.params.type)) errors.push(msg.params.type + ': ' + msg.params.args.map((a) => a.value ?? a.description).join(' '));
};
const send = (method, params = {}) => new Promise((resolve) => { const n = ++id; waiting.set(n, resolve); ws.send(JSON.stringify({ id: n, method, params })); });
const evaluate = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result?.result?.value;
await send('Runtime.enable'); await send('Page.enable');
await send('Page.navigate', { url: `${pageUrl}?user=${encodeURIComponent(user)}` });
await sleep(1500);
if (user === 'guest') {
  // guest seat: the nickname is the "password" argument
  await evaluate(`document.getElementById('nick').value = ${JSON.stringify(password)}; document.getElementById('go').click(); 'clicked'`);
} else {
  await evaluate(`const t = document.getElementById('account-toggle'); if (t && !t.hidden && document.getElementById('user-field').hidden) t.click(); document.getElementById('user').value = ${JSON.stringify(user)}; document.getElementById('password').value = ${JSON.stringify(password)}; document.getElementById('go').click(); 'clicked'`);
}
for (let i = 0; i < 60; i++) { await sleep(500); if ((await evaluate(`document.getElementById('status').textContent`)).includes('in the game')) break; }
console.log('status:', await evaluate(`document.getElementById('status').textContent`));
await evaluate(`document.getElementById('stage').focus(); 'ok'`);
const key = (type, code, keyName, windowsVirtualKeyCode) => send('Input.dispatchKeyEvent', { type, code, key: keyName, windowsVirtualKeyCode });
await key('keyDown', 'KeyW', 'w', 87); await key('keyDown', 'ArrowRight', 'ArrowRight', 39);
await sleep(seconds * 1000 / 2);
await key('keyUp', 'ArrowRight', 'ArrowRight', 39); await key('keyDown', 'ControlLeft', 'Control', 17);
await sleep(seconds * 1000 / 2);
await key('keyUp', 'KeyW', 'w', 87); await key('keyUp', 'ControlLeft', 'Control', 17);
console.log('stats: ', await evaluate(`document.getElementById('stats').textContent`));
await key('keyDown', 'Tab', 'Tab', 9); await key('keyUp', 'Tab', 'Tab', 9); await sleep(1500);
console.log('automap:', await evaluate(`(() => { const c = document.getElementById('screen').getContext('2d'); const d = c.getImageData(0, 0, 320, 200).data; let red = 0, lit = 0; for (let i = 0; i < d.length; i += 4) { if (d[i] > 120 && d[i+1] < 60 && d[i+2] < 60) red++; if (d[i] + d[i+1] + d[i+2] > 30) lit++; } return red + ' red wall pixels, ' + lit + ' lit of 64000'; })()`));
if (shot) { const png = (await send('Page.captureScreenshot', { format: 'png' })).result.data; writeFileSync(shot.replace(/\.png$/, '') + '.automap.png', Buffer.from(png, 'base64')); }
await key('keyDown', 'Tab', 'Tab', 9); await key('keyUp', 'Tab', 'Tab', 9); await sleep(300);
console.log('canvas:', await evaluate(`(() => { const c = document.getElementById('screen').getContext('2d'); const d = c.getImageData(0, 0, 320, 200).data; let lit = 0, sum = 0; for (let i = 0; i < d.length; i += 4) { const v = d[i] + d[i+1] + d[i+2]; sum += v; if (v > 30) lit++; } return lit + ' of 64000 pixels lit, mean ' + (sum / 64000 / 3).toFixed(1); })()`));
console.log('score: ', await evaluate(`document.getElementById('scoreboard').textContent.replace(/\\s+/g, ' ').trim()`));
if (shot) { const png = (await send('Page.captureScreenshot', { format: 'png' })).result.data; writeFileSync(shot, Buffer.from(png, 'base64')); console.log('screenshot:', shot); }
console.log(errors.length ? 'console errors:\n  ' + errors.slice(0, 10).join('\n  ') : 'console: no errors or warnings');
ws.close(); chrome.kill();
process.exit(errors.some((e) => e.startsWith('exception')) ? 1 : 0);
