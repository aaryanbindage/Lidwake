'use strict';
// LidWake relay — gives each Mac a permanent https address without the Mac
// accepting inbound connections. The Mac (lidwaked) long-polls this server;
// browsers post requests that are end-to-end encrypted (AES-256-GCM) with a key
// that only the Mac and the link's #fragment know. This server only ever sees
// random device IDs and ciphertext. Optional accounts (accounts.js) keep each
// user's Mac links in a database, encrypted in the browser with a key the server
// never sees. Deploy with ../render.yaml, or run: node relay/server.js
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { openStore } = require('./store');
const { createAccounts } = require('./accounts');

const PORT = Number(process.env.PORT) || 10000;
const PAGE = fs.readFileSync(path.join(__dirname, '..', 'remote', 'index.html'));
const POLL_MS = 25_000;        // how long a Mac's poll is held open
const REPLY_MS = 25_000;       // how long a browser waits for the Mac
const ONLINE_MS = 40_000;      // a Mac that polled this recently counts as online
const MAX_BODY = 64 * 1024;
const MAX_PENDING = 20;        // per device
const MAX_DEVICES = 10_000;

const AGENT_ERRORS = {
  undecryptable: 'The Mac couldn’t decrypt this request — this link is out of date. Get the current one on the Mac with: lidwake remote',
  stale: 'The Mac rejected an expired request — check that this device’s clock is set correctly.',
};

// id -> { seen, waiter, waitTimer, queue: [{id, data}], pending: Map(reqId -> {res, timer}) }
const devices = new Map();

const SECURITY_HEADERS = {
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Strict-Transport-Security': 'max-age=31536000',
};

function send(res, status, obj) {
  if (res.writableEnded || res.headersSent) return;
  res.writeHead(status, { ...SECURITY_HEADERS, 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}

function httpError(status, message) {
  return Object.assign(new Error(message), { status, expose: true });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(httpError(413, 'request too large')); req.destroy(); } else chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')); }
      catch { reject(httpError(400, 'bad JSON')); }
    });
    req.on('error', reject);
  });
}

// The Mac proves it owns a device ID by sending the secret it was derived from.
// Stateless, so it survives relay restarts (Render's free tier restarts often).
function agentId(req) {
  const secret = String(req.headers['x-agent-secret'] || '');
  if (!/^[0-9a-f]{64}$/.test(secret)) return null;
  return crypto.createHash('sha256').update(secret).digest('hex').slice(0, 32);
}

function getDevice(id) {
  let dev = devices.get(id);
  if (!dev && devices.size < MAX_DEVICES) {
    dev = { seen: 0, waiter: null, waitTimer: null, queue: [], pending: new Map() };
    devices.set(id, dev);
  }
  return dev;
}

function releaseWaiter(dev, requests = []) {
  const res = dev.waiter;
  if (!res) return;
  clearTimeout(dev.waitTimer);
  dev.waiter = null;
  dev.seen = Date.now();
  send(res, 200, { requests });
}

function agentPoll(req, res) {
  const id = agentId(req);
  if (!id) return send(res, 401, { error: 'bad agent secret' });
  const dev = getDevice(id);
  if (!dev) return send(res, 503, { error: 'relay is full' });
  dev.seen = Date.now();
  releaseWaiter(dev);                      // a newer poll replaces an older one
  if (dev.queue.length) return send(res, 200, { requests: dev.queue.splice(0) });
  dev.waiter = res;
  dev.waitTimer = setTimeout(() => { if (dev.waiter === res) releaseWaiter(dev); }, POLL_MS);
  res.on('close', () => {
    if (dev.waiter === res) { clearTimeout(dev.waitTimer); dev.waiter = null; }
    dev.seen = Date.now();
  });
}

async function agentReply(req, res) {
  const id = agentId(req);
  if (!id) return send(res, 401, { error: 'bad agent secret' });
  const dev = devices.get(id);
  const body = await readBody(req);
  const waiting = dev && dev.pending.get(body.id);
  if (waiting) {
    dev.pending.delete(body.id);
    clearTimeout(waiting.timer);
    if (typeof body.data === 'string') send(waiting.res, 200, { data: body.data });
    else send(waiting.res, 400, { error: AGENT_ERRORS[body.error] || 'The Mac rejected the request.' });
  }
  send(res, 200, { ok: true });
}

async function browserCall(id, req, res) {
  const body = await readBody(req);
  if (typeof body.data !== 'string' || body.data.length > 48 * 1024) return send(res, 400, { error: 'bad request' });
  const dev = devices.get(id);
  const online = dev && (dev.waiter || Date.now() - dev.seen < ONLINE_MS);
  if (!online) return send(res, 503, { error: 'The Mac is offline or asleep.' });
  if (dev.pending.size >= MAX_PENDING) return send(res, 429, { error: 'Too many requests — slow down.' });

  const reqId = crypto.randomBytes(12).toString('hex');
  const timer = setTimeout(() => {
    dev.pending.delete(reqId);
    send(res, 504, { error: 'The Mac didn’t answer — it may have just gone to sleep.' });
  }, REPLY_MS);
  dev.pending.set(reqId, { res, timer });
  res.on('close', () => {
    if (!res.writableEnded && dev.pending.has(reqId)) { clearTimeout(timer); dev.pending.delete(reqId); }
  });
  dev.queue.push({ id: reqId, data: body.data });
  if (dev.waiter) releaseWaiter(dev, dev.queue.splice(0));
}

const store = openStore();
if (!process.env.AUTH_PEPPER && store) console.warn('AUTH_PEPPER is not set; using a random one for this run');
const accounts = store && createAccounts({
  store, send, readBody, httpError,
  pepper: process.env.AUTH_PEPPER || crypto.randomBytes(32).toString('hex'),
});

function page(res) {
  res.writeHead(200, {
    ...SECURITY_HEADERS,
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Security-Policy':
      "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; " +
      "img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  });
  res.end(PAGE);
}

const server = http.createServer(async (req, res) => {
  try {
    const { pathname } = new URL(req.url, 'http://relay');
    if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) return page(res);
    if (pathname === '/healthz') return send(res, 200, { ok: true, accounts: !!(accounts && accounts.enabled) });
    if (accounts && await accounts.handle(req, res, pathname)) return;
    if (pathname === '/agent/poll' && req.method === 'GET') return agentPoll(req, res);
    if (pathname === '/agent/reply' && req.method === 'POST') return await agentReply(req, res);
    const m = pathname.match(/^\/api\/([0-9a-f]{32})$/);
    if (m && req.method === 'POST') return await browserCall(m[1], req, res);
    send(res, 404, { error: 'not found' });
  } catch (e) {
    send(res, e.status || 500, { error: e.expose ? e.message : 'server error' });
  }
});
server.requestTimeout = 0;          // long polls are held open on purpose
server.headersTimeout = 30_000;

// Forget devices that have been gone for 10 minutes.
setInterval(() => {
  const cutoff = Date.now() - 10 * 60_000;
  for (const [id, dev] of devices) {
    if (!dev.waiter && !dev.pending.size && dev.seen < cutoff) devices.delete(id);
  }
}, 60_000).unref();

server.listen(PORT, () => console.log(`LidWake relay listening on :${PORT}`));
