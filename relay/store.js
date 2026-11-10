'use strict';
// Account storage for the relay. Postgres when DATABASE_URL is set (Render
// Blueprint wires it up), or a JSON file when ACCOUNTS_FILE is set (local or
// self-hosted with a persistent disk). With neither, accounts are disabled.
//
// What's stored is zero-knowledge: a hash of a key the browser derives from the
// password (never the password), and vault items the browser encrypted with a
// second key derived from the password that never leaves the browser.
const fs = require('fs');

const MAX_ITEMS = 50;   // Macs per account

class LimitError extends Error {}

// SSL for anything that isn't local or a Render-internal host (no dots, e.g. dpg-xxx-a).
// Hosted Postgres like Supabase uses its own CA, so the default is encrypted but
// unverified; add ?sslmode=verify-full to verify, or ?sslmode=disable to turn SSL off.
function pgConfig(url) {
  const u = new URL(url);
  const mode = u.searchParams.get('sslmode');
  u.searchParams.delete('sslmode');
  const local = /^(localhost|127\.0\.0\.1|[^.]+)$/.test(u.hostname);
  const ssl = mode === 'disable' || (!mode && local) ? false : { rejectUnauthorized: mode === 'verify-full' };
  return { connectionString: u.toString(), ssl };
}

function pgStore(url, pgModule = require('pg')) {
  const pool = new pgModule.Pool({ ...pgConfig(url), max: 5 });
  pool.on('error', (e) => console.error('postgres:', e.message));
  const q = (text, params) => pool.query(text, params);
  return {
    kind: 'postgres',
    async init() {
      await q(`create table if not exists users (
        email text primary key, salt text not null, auth text not null,
        created timestamptz not null default now())`);
      await q(`create table if not exists sessions (
        token text primary key, email text not null references users(email) on delete cascade,
        expires timestamptz not null)`);
      await q(`create table if not exists vault (
        email text not null references users(email) on delete cascade, id text not null,
        blob text not null, updated timestamptz not null default now(), primary key (email, id))`);
      // Supabase exposes the public schema through its Data API. Row level security with
      // no policies blocks that API completely; the relay connects as the table owner,
      // which RLS doesn't apply to.
      for (const t of ['users', 'sessions', 'vault']) await q(`alter table ${t} enable row level security`);
    },
    async createUser(email, salt, auth) {
      const r = await q('insert into users (email, salt, auth) values ($1, $2, $3) on conflict do nothing', [email, salt, auth]);
      return r.rowCount === 1;
    },
    async getUser(email) {
      return (await q('select email, salt, auth from users where email = $1', [email])).rows[0] || null;
    },
    async deleteUser(email) {
      await q('delete from sessions where email = $1', [email]);
      await q('delete from vault where email = $1', [email]);
      await q('delete from users where email = $1', [email]);
    },
    async createSession(token, email, expires) {
      await q('insert into sessions (token, email, expires) values ($1, $2, $3)', [token, email, new Date(expires)]);
    },
    async getSession(token) {
      const row = (await q('select email, expires from sessions where token = $1', [token])).rows[0];
      return row && new Date(row.expires).getTime() > Date.now() ? row.email : null;
    },
    async deleteSession(token) { await q('delete from sessions where token = $1', [token]); },
    async pruneSessions() { await q('delete from sessions where expires < $1', [new Date()]); },
    async listVault(email) {
      return (await q('select id, blob from vault where email = $1 order by updated', [email])).rows;
    },
    async putVault(email, id, blob) {
      const others = (await q('select count(*)::int as n from vault where email = $1 and id <> $2', [email, id])).rows[0].n;
      if (others >= MAX_ITEMS) throw new LimitError(`An account can hold up to ${MAX_ITEMS} Macs.`);
      await q(`insert into vault (email, id, blob, updated) values ($1, $2, $3, $4)
        on conflict (email, id) do update set blob = excluded.blob, updated = excluded.updated`,
      [email, id, blob, new Date()]);
    },
    async deleteVault(email, id) { await q('delete from vault where email = $1 and id = $2', [email, id]); },
  };
}

function fileStore(file) {
  let db = { users: {}, sessions: {} };
  let writing = Promise.resolve();
  const save = () => {
    const snapshot = JSON.stringify(db);
    writing = writing.then(() => fs.promises.writeFile(file + '.tmp', snapshot, { mode: 0o600 })
      .then(() => fs.promises.rename(file + '.tmp', file)));
    return writing;
  };
  return {
    kind: 'file',
    async init() {
      try { db = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    },
    async createUser(email, salt, auth) {
      if (db.users[email]) return false;
      db.users[email] = { salt, auth, vault: {} };
      await save();
      return true;
    },
    async getUser(email) { const u = db.users[email]; return u ? { email, salt: u.salt, auth: u.auth } : null; },
    async deleteUser(email) {
      delete db.users[email];
      for (const [t, s] of Object.entries(db.sessions)) if (s.email === email) delete db.sessions[t];
      await save();
    },
    async createSession(token, email, expires) { db.sessions[token] = { email, expires }; await save(); },
    async getSession(token) {
      const s = db.sessions[token];
      return s && s.expires > Date.now() && db.users[s.email] ? s.email : null;
    },
    async deleteSession(token) { delete db.sessions[token]; await save(); },
    async pruneSessions() {
      for (const [t, s] of Object.entries(db.sessions)) if (s.expires < Date.now()) delete db.sessions[t];
      await save();
    },
    async listVault(email) {
      const v = (db.users[email] || {}).vault || {};
      return Object.entries(v).sort((a, b) => a[1].updated - b[1].updated).map(([id, x]) => ({ id, blob: x.blob }));
    },
    async putVault(email, id, blob) {
      const v = db.users[email].vault;
      if (!v[id] && Object.keys(v).length >= MAX_ITEMS) throw new LimitError(`An account can hold up to ${MAX_ITEMS} Macs.`);
      v[id] = { blob, updated: Date.now() };
      await save();
    },
    async deleteVault(email, id) { delete db.users[email].vault[id]; await save(); },
  };
}

function openStore(env = process.env) {
  if (env.DATABASE_URL) return pgStore(env.DATABASE_URL);
  if (env.ACCOUNTS_FILE) return fileStore(env.ACCOUNTS_FILE);
  return null;
}

module.exports = { openStore, pgStore, pgConfig, fileStore, LimitError, MAX_ITEMS };
