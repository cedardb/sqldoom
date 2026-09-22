// A small PostgreSQL wire-protocol (v3) client that runs in the browser over a
// WebSocket byte tunnel (doom_web.py). It knows just enough for the game:
// startup, SCRAM-SHA-256 (and cleartext) authentication, simple queries, and
// the extended protocol -- Parse once, then Bind/Execute pipelined under one
// Sync -- with binary result columns for the frame bytes.
//
// SHA-256 is implemented here rather than through crypto.subtle: WebCrypto is
// only available in secure contexts, and a page on a LAN address over plain
// http is not one. PBKDF2 at 4096 rounds in plain JS is a few milliseconds.

const enc = new TextEncoder();
const dec = new TextDecoder();

// ------------------------------------------------------------------ SHA-256
const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

export function sha256(bytes) {
  const n = bytes.length;
  const padded = new Uint8Array(((n + 9 + 63) >> 6) << 6);
  padded.set(bytes);
  padded[n] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 4, n * 8 >>> 0);
  view.setUint32(padded.length - 8, Math.floor(n / 0x20000000));
  const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const w = new Uint32Array(64);
  for (let off = 0; off < padded.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(off + i * 4);
    for (let i = 16; i < 64; i++) {
      const a = w[i - 15], b = w[i - 2];
      const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3);
      const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, hh] = h;
    for (let i = 0; i < 64; i++) {
      const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
      const ch = (e & f) ^ (~e & g);
      const t1 = (hh + S1 + ch + K[i] + w[i]) >>> 0;
      const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      hh = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }
  const out = new Uint8Array(32);
  const ov = new DataView(out.buffer);
  for (let i = 0; i < 8; i++) ov.setUint32(i * 4, h[i]);
  return out;
}

export function hmacSha256(key, message) {
  if (key.length > 64) key = sha256(key);
  const ipad = new Uint8Array(64 + message.length);
  const opad = new Uint8Array(64 + 32);
  for (let i = 0; i < 64; i++) {
    const k = i < key.length ? key[i] : 0;
    ipad[i] = k ^ 0x36;
    opad[i] = k ^ 0x5c;
  }
  ipad.set(message, 64);
  opad.set(sha256(ipad), 64);
  return sha256(opad);
}

function pbkdf2Sha256(password, salt, iterations) {
  const block = new Uint8Array(salt.length + 4);
  block.set(salt);
  block[salt.length + 3] = 1;
  let u = hmacSha256(password, block);
  const out = new Uint8Array(u);
  for (let i = 1; i < iterations; i++) {
    u = hmacSha256(password, u);
    for (let j = 0; j < 32; j++) out[j] ^= u[j];
  }
  return out;
}

const b64 = (bytes) => btoa(String.fromCharCode(...bytes));
const unb64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

// --------------------------------------------------------------- messages
function cstring(text) {
  const b = enc.encode(text);
  const out = new Uint8Array(b.length + 1);
  out.set(b);
  return out;
}

function concat(parts) {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

function int32(v) { const b = new Uint8Array(4); new DataView(b.buffer).setInt32(0, v); return b; }
function int16(v) { const b = new Uint8Array(2); new DataView(b.buffer).setInt16(0, v); return b; }

function message(type, ...parts) {
  const body = concat(parts);
  return concat([Uint8Array.of(type.charCodeAt(0)), int32(body.length + 4), body]);
}

function paramText(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === 'boolean') return value ? 't' : 'f';
  if (value instanceof Uint8Array) return '\\x' + Array.from(value, (b) => b.toString(16).padStart(2, '0')).join('');
  return String(value);
}

export const OID = { bool: 16, int8: 20, int4: 23, text: 25, float4: 700, float8: 701 };

export class PgError extends Error {
  constructor(fields) {
    super(fields.M || 'database error');
    this.code = fields.C;
    this.fields = fields;
  }
}

export class PgConnection {
  // protocols: WebSocket subprotocols to ask the relay for. 'pg-delta' makes
  // it XOR every large binary column against the previous one of the same
  // size before compressing; this client undoes it when `this.delta` is set.
  constructor(url, protocols = []) {
    this.url = url;
    this.protocols = protocols;
    this.delta = false;
    this._prev = new Map();
    this.buffer = new Uint8Array(0);
    this.pending = [];       // requests awaiting their ReadyForQuery, in order
    this.ws = null;
    this.onclose = null;
    this.parameters = {};
    this._auth = null;
  }

  // guest: the relay picks the login and sends it as a JSON text frame before
  // any Postgres bytes flow; the startup message waits for it.
  connect({ user, password, database = 'postgres', guest = false }) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url, this.protocols);
      ws.binaryType = 'arraybuffer';
      this.ws = ws;
      this._auth = { user, password, resolve, reject };
      this.user = user;
      const startup = () => {
        const params = concat([cstring('user'), cstring(this._auth.user), cstring('database'), cstring(database),
          cstring('client_encoding'), cstring('UTF8'), cstring('application_name'), cstring('doom-web'),
          Uint8Array.of(0)]);
        this._send(concat([int32(params.length + 8), int32(196608), params]));
      };
      ws.onopen = () => { this.delta = ws.protocol === 'pg-delta'; if (!guest) startup(); };
      ws.onmessage = (ev) => {
        if (typeof ev.data === 'string') {
          let msg;
          try { msg = JSON.parse(ev.data); } catch (e) { msg = { error: 'bad relay message' }; }
          // The relay's byte count, once a second: what this connection has
          // cost on the wire so far, which the page cannot measure itself.
          if (msg.wire_out !== undefined) { this.wire = msg; if (this.onwire) this.onwire(msg); return; }
          if (msg.error || !this._auth) { const err = new Error(msg.error || 'relay refused'); if (this._auth) { this._auth.reject(err); this._auth = null; } return; }
          this._auth.user = msg.user; this._auth.password = msg.password; this.user = msg.user;
          startup();
          return;
        }
        this._feed(new Uint8Array(ev.data));
      };
      ws.onerror = () => { /* onclose follows with the reason */ };
      ws.onclose = (ev) => {
        const err = new Error(`connection closed (${ev.code}${ev.reason ? ': ' + ev.reason : ''})`);
        if (this._auth) { this._auth.reject(err); this._auth = null; }
        for (const req of this.pending) req.reject(err);
        this.pending = [];
        if (this.onclose) this.onclose(err);
      };
    });
  }

  close() { if (this.ws) this.ws.close(1000); }

  _send(bytes) { this.ws.send(bytes); }

  // A simple query: one text; returns [{columns, rows}] (one per statement).
  query(sql) {
    return this._request(message('Q', cstring(sql)));
  }

  // Parse a named statement once. oids: parameter type OIDs (see OID).
  async prepare(name, sql, oids = []) {
    const parts = [cstring(name), cstring(sql), int16(oids.length)];
    for (const oid of oids) parts.push(int32(oid));
    await this._request(concat([message('P', ...parts), message('S')]));
  }

  // Run prepared statements back to back under one Sync: one round trip.
  // steps: [{name, params: [], binary: false}] -> [{columns, rows}] per step.
  run(steps) {
    const formats = steps.map((step) => (step.binary ? 1 : 0));
    const parts = [];
    for (const step of steps) {
      const params = step.params || [];
      const bind = [cstring(''), cstring(step.name), int16(1), int16(0), int16(params.length)];
      for (const value of params) {
        const text = paramText(value);
        if (text === null) bind.push(int32(-1));
        else { const b = enc.encode(text); bind.push(int32(b.length), b); }
      }
      bind.push(int16(1), int16(step.binary ? 1 : 0));
      parts.push(message('B', ...bind), message('E', cstring(''), int32(0)));
    }
    parts.push(message('S'));
    return this._request(concat(parts), formats);
  }

  // formats: the result format each step asked for. Execute without Describe
  // brings no RowDescription, so the rows are decoded by what we asked for.
  _request(bytes, formats = null) {
    return new Promise((resolve, reject) => {
      this.pending.push({ resolve, reject, results: [], current: null, error: null, formats });
      this._send(bytes);
    });
  }

  _feed(chunk) {
    if (this.buffer.length) {
      const merged = new Uint8Array(this.buffer.length + chunk.length);
      merged.set(this.buffer); merged.set(chunk, this.buffer.length);
      this.buffer = merged;
    } else {
      this.buffer = chunk;
    }
    let off = 0;
    while (this.buffer.length - off >= 5) {
      const view = new DataView(this.buffer.buffer, this.buffer.byteOffset + off);
      const len = view.getInt32(1);
      if (this.buffer.length - off < 1 + len) break;
      this._dispatch(String.fromCharCode(this.buffer[off]), this.buffer.subarray(off + 5, off + 1 + len));
      off += 1 + len;
    }
    this.buffer = off ? this.buffer.slice(off) : this.buffer;
  }

  _dispatch(type, body) {
    const view = new DataView(body.buffer, body.byteOffset, body.byteLength);
    switch (type) {
      case 'R': return this._authentication(view, body);
      case 'S': { // ParameterStatus
        const [k, v] = readCStrings(body, 2);
        this.parameters[k] = v;
        return;
      }
      case 'K': case '1': case '2': case '3': case 'n': case 's': return;
      case 'N': { console.warn('[pg notice]', parseFields(body).M); return; }
      case 'E': {
        const fields = parseFields(body);
        if (this._auth) { this._auth.reject(new PgError(fields)); this._auth = null; return; }
        const req = this.pending[0];
        if (req) req.error = new PgError(fields);
        return;
      }
      case 'T': {
        const req = this.pending[0];
        if (!req) return;
        const n = view.getInt16(0);
        const columns = [];
        let off = 2;
        for (let i = 0; i < n; i++) {
          const end = body.indexOf(0, off);
          const name = dec.decode(body.subarray(off, end));
          off = end + 1;
          const typeOid = view.getInt32(off + 6);
          const format = view.getInt16(off + 16);
          off += 18;
          columns.push({ name, typeOid, format });
        }
        req.current = { columns, rows: [] };
        return;
      }
      case 'D': {
        const req = this.pending[0];
        if (!req) return;
        if (!req.current) req.current = { columns: [], rows: [] };
        const n = view.getInt16(0);
        const row = new Array(n);
        let off = 2;
        for (let i = 0; i < n; i++) {
          const len = view.getInt32(off);
          off += 4;
          if (len < 0) { row[i] = null; continue; }
          const cell = body.subarray(off, off + len);
          const col = req.current.columns[i];
          const format = col ? col.format : (req.formats ? req.formats[req.results.length] : 0);
          if (format === 1) {
            const copy = cell.slice();
            if (this.delta && n === 1 && len >= 32768) {
              // the relay sent this XORed against the previous cell of this size
              const prev = this._prev.get(len);
              if (prev) { for (let k = 0; k < len; k++) copy[k] ^= prev[k]; }
              this._prev.set(len, copy);
            }
            row[i] = copy;
          } else {
            row[i] = dec.decode(cell);
          }
          off += len;
        }
        req.current.rows.push(row);
        return;
      }
      case 'C': case 'I': {
        const req = this.pending[0];
        if (!req) return;
        req.results.push(req.current || { columns: [], rows: [] });
        req.current = null;
        return;
      }
      case 'Z': {
        if (this._auth) { const a = this._auth; this._auth = null; a.resolve(this); return; }
        const req = this.pending.shift();
        if (!req) return;
        if (req.error) req.reject(req.error); else req.resolve(req.results);
        return;
      }
      default:
        return;
    }
  }

  _authentication(view, body) {
    const code = view.getInt32(0);
    const auth = this._auth;
    if (!auth) return;
    if (code === 0) return;                                  // AuthenticationOk; ReadyForQuery follows
    if (code === 3) { this._send(message('p', cstring(auth.password))); return; }
    if (code === 10) {                                       // SASL: pick SCRAM-SHA-256
      const mechanisms = dec.decode(body.subarray(4)).split('\0').filter(Boolean);
      if (!mechanisms.includes('SCRAM-SHA-256')) {
        auth.reject(new Error(`server offers ${mechanisms.join(', ')}; only SCRAM-SHA-256 is supported`));
        return;
      }
      const nonce = new Uint8Array(18);
      crypto.getRandomValues(nonce);
      auth.nonce = b64(nonce);
      auth.firstBare = `n=${auth.user.replace(/=/g, '=3D').replace(/,/g, '=2C')},r=${auth.nonce}`;
      const first = enc.encode('n,,' + auth.firstBare);
      this._send(message('p', cstring('SCRAM-SHA-256'), int32(first.length), first));
      return;
    }
    if (code === 11) {                                       // SASLContinue: server-first-message
      const serverFirst = dec.decode(body.subarray(4));
      const attrs = Object.fromEntries(serverFirst.split(',').map((kv) => [kv[0], kv.slice(2)]));
      if (!attrs.r || !attrs.r.startsWith(auth.nonce)) { auth.reject(new Error('SCRAM nonce mismatch')); return; }
      const salted = pbkdf2Sha256(enc.encode(auth.password), unb64(attrs.s), parseInt(attrs.i, 10));
      const clientKey = hmacSha256(salted, enc.encode('Client Key'));
      const storedKey = sha256(clientKey);
      const finalWithoutProof = `c=biws,r=${attrs.r}`;
      const authMessage = enc.encode(`${auth.firstBare},${serverFirst},${finalWithoutProof}`);
      const signature = hmacSha256(storedKey, authMessage);
      const proof = new Uint8Array(32);
      for (let i = 0; i < 32; i++) proof[i] = clientKey[i] ^ signature[i];
      auth.serverSignature = b64(hmacSha256(hmacSha256(salted, enc.encode('Server Key')), authMessage));
      this._send(message('p', enc.encode(`${finalWithoutProof},p=${b64(proof)}`)));
      return;
    }
    if (code === 12) {                                       // SASLFinal: verify the server
      const final = dec.decode(body.subarray(4));
      if (final !== `v=${auth.serverSignature}`) auth.reject(new Error('SCRAM server signature mismatch'));
      return;
    }
    auth.reject(new Error(`unsupported authentication request ${code}`));
  }
}

function readCStrings(body, count) {
  const out = [];
  let off = 0;
  for (let i = 0; i < count; i++) {
    const end = body.indexOf(0, off);
    out.push(dec.decode(body.subarray(off, end)));
    off = end + 1;
  }
  return out;
}

function parseFields(body) {
  const fields = {};
  let off = 0;
  while (off < body.length && body[off] !== 0) {
    const code = String.fromCharCode(body[off]);
    const end = body.indexOf(0, off + 1);
    fields[code] = dec.decode(body.subarray(off + 1, end));
    off = end + 1;
  }
  return fields;
}
