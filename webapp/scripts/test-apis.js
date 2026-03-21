#!/usr/bin/env node
'use strict';

/**
 * Test all Web APIs against a running server.
 * Use before Docker deploy to prove every endpoint responds correctly.
 *
 * Usage:
 *   1. Start the server: npm start  (or node server/index.js)
 *   2. Run: node scripts/test-apis.js
 *   Or with custom URL: BASE_URL=https://10.235.160.31:3443 node scripts/test-apis.js
 *
 * For HTTPS with self-signed cert: NODE_TLS_REJECT_UNAUTHORIZED=0 node scripts/test-apis.js
 */

const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';
const results = [];

function log(name, pass, detail = '') {
  const tag = pass ? '[PASS]' : '[FAIL]';
  console.log(`${tag} ${name}${detail ? ' — ' + detail : ''}`);
  results.push({ name, pass });
}

async function fetchJson(url, options = {}) {
  const res = await fetch(url, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...options.headers },
  });
  const text = await res.text();
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = {};
  }
  return { ok: res.ok, status: res.status, body, text };
}

async function run() {
  console.log('\n--- API test (target: ' + BASE_URL + ') ---\n');

  // GET /api/version
  try {
    const { status, body } = await fetchJson(BASE_URL + '/api/version');
    const pass = status === 200 && body && body.ok === true && typeof body.version === 'string';
    log('GET /api/version', pass, pass ? 'v' + body.version : 'status=' + status);
  } catch (e) {
    log('GET /api/version', false, e.message);
  }

  // GET /api/config
  try {
    const { status, body } = await fetchJson(BASE_URL + '/api/config');
    const pass = status === 200 && body && body.ok === true;
    log('GET /api/config', pass, pass ? '' : 'status=' + status + (body.error ? ' ' + body.error : ''));
  } catch (e) {
    log('GET /api/config', false, e.message);
  }

  // GET /api/topics
  try {
    const { status, body } = await fetchJson(BASE_URL + '/api/topics');
    const pass = status === 200 && body && typeof body.ok !== 'undefined' && Array.isArray(body.topics);
    log('GET /api/topics', pass, pass ? '(topics: ' + (body.topics?.length ?? 0) + ')' : 'status=' + status + (body.error ? ' ' + body.error : ''));
  } catch (e) {
    log('GET /api/topics', false, e.message);
  }

  // GET /api/users
  try {
    const { status, body } = await fetchJson(BASE_URL + '/api/users');
    const pass = status === 200 && body && typeof body.ok !== 'undefined' && Array.isArray(body.users);
    log('GET /api/users', pass, pass ? '(users: ' + (body.users?.length ?? 0) + ')' : 'status=' + status + (body.error ? ' ' + body.error : ''));
  } catch (e) {
    log('GET /api/users', false, e.message);
  }

  // GET /api/download path traversal — 400 (reject) or 404 (normalized path) = ไม่ส่งไฟล์ = ผ่าน
  try {
    const res = await fetch(BASE_URL + '/api/download/../etc/passwd');
    const pass = res.status === 400 || res.status === 404;
    log('GET /api/download (path traversal)', pass, pass ? 'status=' + res.status : 'expected 400 or 404, got ' + res.status);
  } catch (e) {
    log('GET /api/download (path traversal)', false, e.message);
  }

  // POST /api/add-user — validation (empty body => 400)
  try {
    const { status, body } = await fetchJson(BASE_URL + '/api/add-user', {
      method: 'POST',
      body: '{}',
    });
    const pass = status === 400 && body && (body.errors || body.error);
    log('POST /api/add-user (validation)', pass, pass ? '' : 'expected 400, got ' + status);
  } catch (e) {
    log('POST /api/add-user (validation)', false, e.message);
  }

  // POST /api/test-user — validation
  try {
    const { status } = await fetchJson(BASE_URL + '/api/test-user', { method: 'POST', body: '{}' });
    log('POST /api/test-user (validation)', status === 400, status === 400 ? '' : 'got ' + status);
  } catch (e) {
    log('POST /api/test-user (validation)', false, e.message);
  }

  // POST /api/remove-user — validation
  try {
    const { status } = await fetchJson(BASE_URL + '/api/remove-user', { method: 'POST', body: '{}' });
    log('POST /api/remove-user (validation)', status === 400, status === 400 ? '' : 'got ' + status);
  } catch (e) {
    log('POST /api/remove-user (validation)', false, e.message);
  }

  // POST /api/change-password — validation
  try {
    const { status } = await fetchJson(BASE_URL + '/api/change-password', { method: 'POST', body: '{}' });
    log('POST /api/change-password (validation)', status === 400, status === 400 ? '' : 'got ' + status);
  } catch (e) {
    log('POST /api/change-password (validation)', false, e.message);
  }

  // POST /api/cleanup-acl — must respond (200 or 500)
  try {
    const { status, body } = await fetchJson(BASE_URL + '/api/cleanup-acl', { method: 'POST', body: '{}' });
    const pass = status === 200 || status === 500;
    log('POST /api/cleanup-acl', pass, 'status=' + status + (body.error ? ' (' + body.error + ')' : ''));
  } catch (e) {
    log('POST /api/cleanup-acl', false, e.message);
  }

  // gen.sh reachable — 500 must NOT be spawn ENOENT / gen.sh not found (check only body.error)
  try {
    const { status, body } = await fetchJson(BASE_URL + '/api/cleanup-acl', { method: 'POST', body: '{}' });
    const err = (body && body.error) || '';
    const badPath = /not found at|gen\.sh not found/i.test(err);
    const badBash = /ENOENT|spawn bash/i.test((body && body.error) || '');
    const pass = status === 200 || (status === 500 && !badBash && !badPath);
    log('gen.sh reachable', pass, pass ? '' : (badBash || badPath ? err : 'status=' + status));
  } catch (e) {
    log('gen.sh reachable', false, e.message);
  }

  // --- ทุก Function/Menu: แต่ละ API เรียก gen.sh ได้จริง (200 หรือ 500 จาก gen.sh ไม่ใช่ ENOENT/not found) ---
  console.log('\n--- ทุก Function (Add/Test/Remove/Change/Cleanup) เรียก gen.sh ได้จริง ---');
  function checkGenFunction(name, path, bodyObj) {
    return fetchJson(BASE_URL + '/api/' + path, { method: 'POST', body: JSON.stringify(bodyObj) });
  }
  async function assertGenReachable(name, path, bodyObj) {
    try {
      const { status, body } = await checkGenFunction(name, path, bodyObj);
      const err = (body && body.error) || '';
      const badBash = /ENOENT|spawn bash/i.test(err);
      const badPath = /not found at|gen\.sh not found/i.test(err);
      const scriptRan = status === 200 || (status === 500 && (err.includes('gen.sh exited') || !badBash && !badPath));
      const pass = scriptRan;
      log(name, pass, pass ? '' : (status === 400 ? 'validation 400' : err || 'status=' + status));
    } catch (e) {
      log(name, false, e.message);
    }
  }
  await assertGenReachable('Add user (add-user)', 'add-user', {
    systemName: 'DeployCheck', topic: '__deploy_check_topic__', username: '__deploy_check_user__',
    acl: 'read', passphrase: 'x', confirmPassphrase: 'x',
  });
  await assertGenReachable('Test user (test-user)', 'test-user', { username: '__deploy_check_user__', password: 'x', topic: '__deploy_check_topic__' });
  await assertGenReachable('Remove user (remove-user)', 'remove-user', { users: ['__no_such_user_xyz__'] });
  await assertGenReachable('Change password (change-password)', 'change-password', { username: '__no_such_user_xyz__', newPassword: 'x' });
  await assertGenReachable('Cleanup ACL (cleanup-acl)', 'cleanup-acl', {});

  const passed = results.filter((r) => r.pass).length;
  const total = results.length;
  console.log('\n--- Result: ' + passed + '/' + total + ' passed ---\n');
  process.exit(passed === total ? 0 : 1);
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
