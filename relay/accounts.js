'use strict';
// Optional accounts: sign in on any device and your Macs are already there.
//
// Zero-knowledge by design. The browser runs PBKDF2-SHA256 (600k rounds) on the
// password and splits the output in two:
//   auth key — sent here; stored only as a salted scrypt hash. Proves who you are.
//   vault key — never leaves the browser; encrypts each Mac's {device, key} link.
// So this server (and its database) can't read the links, and a database leak
// gives an attacker nothing they can use without cracking each password.
const crypto = require('crypto');
const { promisify } = require('util');
const { LimitError } = require('./store');

const scrypt = promisify(crypto.scrypt);
const ITERATIONS = 600_000;            // PBKDF2 rounds the browser runs
const SESSION_MS = 90 * 24 * 3600_000;
const B64_16 = /^[A-Za-z0-9+/]{22}==$/;
const B64_32 = /^[A-Za-z0-9+/]{43}=$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const DEVICE_ID = /^[0-9a-f]{32}$/;

function createAccounts({ store, pepper, send, readBody, httpError }) {
  let ready = false;
  const connect = () => store.init().then(
    () => { ready = true; console.log(`accounts: using ${store.kind} storage`); },
    (e) => { console.error(`accounts: storage unavailable (${e.message}); retrying in 15s`); setTimeout(connect, 15_000); });
  connect();
  setInterval(() => { if (ready) store.pruneSessions().catch(() => {}); }, 3600_000).unref();

  // ---- brute-force limits (in memory; per IP and per account) ----
  const strikes = new Map();             // key -> { n, reset }
  const WINDOW = 15 * 60_000;
  const over = (key, max) => { const s = strikes.get(key); return !!s && s.reset > Date.now() && s.n >= max; };
  const strike = (key) => {
    let s = strikes.get(key);
    if (!s || s.reset < Date.now()) strikes.set(key, s = { n: 0, reset: Date.now() + WINDOW });
    s.n++;
  };
  setInterval(() => { for (const [k, s] of strikes) if (s.reset < Date.now()) strikes.delete(k); }, 60_000).unref();

  const clientIp = (req) => String(req.headers['x-forwarded-for'] || '').split(',')[0].trim() || req.socket.remoteAddress;
  const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');

  function email(body) {
    const e = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
    if (e.length > 254 || !EMAIL.test(e)) throw httpError(400, 'Enter a valid email address.');
    return e;
  }
  function authKey(body) {
    if (typeof body.auth !== 'string' || !B64_32.test(body.auth)) throw httpError(400, 'bad request');
    return Buffer.from(body.auth, 'base64');
  }
  async function hashAuth(key, salt = crypto.randomBytes(16)) {
    const h = await scrypt(key, salt, 32, { N: 16384, r: 8, p: 1 });
    return `s1$${salt.toString('hex')}$${h.toString('hex')}`;
  }
  async function authMatches(key, stored) {
    const [, salt, hash] = stored.split('$');
    const h = await scrypt(key, Buffer.from(salt, 'hex'), 32, { N: 16384, r: 8, p: 1 });
    return crypto.timingSafeEqual(h, Buffer.from(hash, 'hex'));
  }
  // Unknown accounts get a stable, fake salt so the salt lookup doesn't reveal who has an account.
  const fakeSalt = (e) => crypto.createHmac('sha256', pepper).update('salt:' + e).digest().subarray(0, 16).toString('base64');

  async function newSession(res, status, e) {
    const token = crypto.randomBytes(32).toString('base64url');
    await store.createSession(sha256(token), e, Date.now() + SESSION_MS);
    send(res, status, { session: token, email: e });
  }

  async function sessionEmail(req) {
    const m = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(req.headers.authorization || '');
    const e = m && await store.getSession(sha256(m[1]));
    if (!e) throw httpError(401, 'Your sign-in expired — sign in again.');
    return { email: e, token: m[1] };
  }

  async function handle(req, res, pathname) {
    if (!pathname.startsWith('/auth/') && !pathname.startsWith('/vault')) return false;
    if (!ready) throw httpError(503, 'Accounts are temporarily unavailable — try again in a minute.');
    const ip = clientIp(req);
    const route = `${req.method} ${pathname.replace(/[0-9a-f]{32}$/, ':id')}`;

    switch (route) {
      case 'POST /auth/params': {
        const e = email(await readBody(req));
        const user = await store.getUser(e);
        send(res, 200, { salt: user ? user.salt : fakeSalt(e), iterations: ITERATIONS });
        return true;
      }
      case 'POST /auth/signup': {
        const body = await readBody(req);
        const e = email(body);
        if (typeof body.salt !== 'string' || !B64_16.test(body.salt)) throw httpError(400, 'bad request');
        const key = authKey(body);
        if (over('signup:' + ip, 10)) throw httpError(429, 'Too many new accounts from here — try again later.');
        strike('signup:' + ip);
        if (!await store.createUser(e, body.salt, await hashAuth(key))) {
          throw httpError(409, 'There’s already an account with that email — sign in instead.');
        }
        await newSession(res, 201, e);
        return true;
      }
      case 'POST /auth/login': {
        const body = await readBody(req);
        const e = email(body);
        const key = authKey(body);
        if (over('ip:' + ip, 10) || over('acct:' + e, 20)) {
          throw httpError(429, 'Too many wrong passwords — wait 15 minutes and try again.');
        }
        const user = await store.getUser(e);
        const ok = user ? await authMatches(key, user.auth) : (await hashAuth(key), false);
        if (!ok) {
          strike('ip:' + ip);
          strike('acct:' + e);
          throw httpError(401, 'Wrong email or password.');
        }
        await newSession(res, 200, e);
        return true;
      }
      case 'POST /auth/logout': {
        const { token } = await sessionEmail(req);
        await store.deleteSession(sha256(token));
        send(res, 200, { ok: true });
        return true;
      }
      case 'POST /auth/delete': {
        const { email: e } = await sessionEmail(req);
        const key = authKey(await readBody(req));
        const user = await store.getUser(e);
        if (over('acct:' + e, 20) || !user || !await authMatches(key, user.auth)) {
          strike('acct:' + e);
          throw httpError(401, 'Wrong password.');
        }
        await store.deleteUser(e);
        send(res, 200, { ok: true });
        return true;
      }
      case 'GET /vault': {
        const { email: e } = await sessionEmail(req);
        send(res, 200, { email: e, items: await store.listVault(e) });
        return true;
      }
      case 'PUT /vault/:id':
      case 'DELETE /vault/:id': {
        const { email: e } = await sessionEmail(req);
        const id = pathname.slice('/vault/'.length);
        if (!DEVICE_ID.test(id)) throw httpError(404, 'not found');
        if (req.method === 'DELETE') {
          await store.deleteVault(e, id);
        } else {
          const { blob } = await readBody(req);
          if (typeof blob !== 'string' || blob.length > 4096 || !/^[A-Za-z0-9+/=]+$/.test(blob)) throw httpError(400, 'bad request');
          try { await store.putVault(e, id, blob); } catch (err) {
            if (err instanceof LimitError) throw httpError(400, err.message);
            throw err;
          }
        }
        send(res, 200, { ok: true });
        return true;
      }
    }
    throw httpError(404, 'not found');
  }

  return { get enabled() { return ready; }, handle };
}

module.exports = { createAccounts, ITERATIONS };
