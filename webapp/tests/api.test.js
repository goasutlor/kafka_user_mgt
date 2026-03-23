'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const fs = require('fs');
const os = require('node:os');
const request = require('supertest');

const configPath = path.join(__dirname, '..', 'config', 'web.config.json');

// Use test config so API tests pass without real gen.sh (scriptPath must exist).
const fixturesDir = path.join(__dirname, 'fixtures');
if (!fs.existsSync(fixturesDir)) fs.mkdirSync(fixturesDir, { recursive: true });
const dummyScript = path.join(fixturesDir, 'dummy-gen.sh');
if (!fs.existsSync(dummyScript)) fs.writeFileSync(dummyScript, '#!/usr/bin/env bash\nexit 0\n', 'utf8');
const testConfigPath = path.join(fixturesDir, 'web.config.test.json');
const mainConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const testConfig = {
  ...mainConfig,
  gen: { ...mainConfig.gen, scriptPath: dummyScript, baseDir: fixturesDir },
};
fs.writeFileSync(testConfigPath, JSON.stringify(testConfig, null, 2));
process.env.CONFIG_PATH = testConfigPath;

describe('web.config.json', () => {
  it('config file exists', () => {
    assert.ok(fs.existsSync(configPath), 'web.config.json should exist');
  });

  it('config has gen and server', () => {
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    assert.ok(config.gen, 'config.gen required');
    assert.ok(config.gen.scriptPath, 'config.gen.scriptPath required');
    assert.ok(config.gen.baseDir, 'config.gen.baseDir required');
    assert.ok(config.gen.kafkaBin, 'config.gen.kafkaBin required');
    assert.strictEqual(typeof config.server?.port, 'number', 'config.server.port should be number');
  });
});

describe('API', () => {
  const { app, loadConfig, parsePackFromStdout, buildDecryptInstructions } = require('../server/index.js');

  it('GET /api/setup/status reports setup not required when test config exists', async () => {
    const res = await request(app).get('/api/setup/status').expect(200);
    assert.strictEqual(res.body.ok, true);
    assert.strictEqual(res.body.setupRequired, false);
    assert.ok(typeof res.body.configPath === 'string');
    assert.ok(typeof res.body.setupPageUrl === 'string' && res.body.setupPageUrl.includes('/setup.html'));
    assert.ok(typeof res.body.appUrl === 'string');
    assert.strictEqual(typeof res.body.reconfigureAllowed, 'boolean');
  });

  it('GET /api/setup/prefill returns 400 for legacy web.config (not master format)', async () => {
    const res = await request(app).get('/api/setup/prefill').expect(400);
    assert.strictEqual(res.body.ok, false);
    assert.ok(String(res.body.error || '').includes('master'));
  });

  it('GET /api/preflight/golive without GOLIVE_REPORT_TOKEN returns 503', async () => {
    const prev = process.env.GOLIVE_REPORT_TOKEN;
    delete process.env.GOLIVE_REPORT_TOKEN;
    try {
      const res = await request(app).get('/api/preflight/golive').expect(503);
      assert.strictEqual(res.body.ok, false);
    } finally {
      if (prev !== undefined) process.env.GOLIVE_REPORT_TOKEN = prev;
    }
  });

  it('GET /api/preflight/golive with wrong X-Golive-Token returns 403', async () => {
    const prev = process.env.GOLIVE_REPORT_TOKEN;
    process.env.GOLIVE_REPORT_TOKEN = 'golive-test-token';
    try {
      await request(app).get('/api/preflight/golive').expect(403);
      await request(app).get('/api/preflight/golive').set('X-Golive-Token', 'nope').expect(403);
    } finally {
      if (prev === undefined) delete process.env.GOLIVE_REPORT_TOKEN;
      else process.env.GOLIVE_REPORT_TOKEN = prev;
    }
  });

  it('POST /api/setup/preview accepts dual OCP topology and returns checks', async () => {
    const res = await request(app)
      .post('/api/setup/preview')
      .send({
        runtimeRoot: '/opt/kafka-usermgmt',
        kafkaBootstrap: 'broker1:443,broker2:443',
        ocTopology: 'dual',
        ocSites: [
          { ocContext: 'cwdc', namespace: 'esb-prod-cwdc', apiServer: 'https://api.cwdc.example:6443' },
          { ocContext: 'tls2', namespace: 'esb-prod-tls2', apiServer: 'https://api.tls2.example:6443' },
        ],
        ocAutoLogin: true,
        ocLoginUser: 'svc_ocp',
        ocLoginPassword: 'secret',
      })
      .expect(200);
    assert.strictEqual(res.body.ok, true);
    assert.strictEqual(res.body.summary.topology, 'dual_ocp');
    assert.ok(Array.isArray(res.body.checks));
    assert.strictEqual(res.body.canSave, true);
  });

  it('loadConfig loads web.config.json', () => {
    const c = loadConfig();
    assert.ok(c.gen);
    assert.ok(c.gen.scriptPath);
  });

  // ---- Add user: validation ----
  it('POST /api/add-user without body returns 400', async () => {
    const res = await request(app).post('/api/add-user').send({}).expect(400);
    assert.ok(Array.isArray(res.body.errors));
    assert.ok(res.body.errors.some((e) => /systemName|topic|username/.test(e)));
  });

  it('POST /api/add-user with only systemName returns 400', async () => {
    await request(app).post('/api/add-user').send({ systemName: 'TEST' }).expect(400);
  });

  it('POST /api/add-user without passphrase returns 400', async () => {
    const res = await request(app)
      .post('/api/add-user')
      .send({
        systemName: 'TestSystem',
        topic: 'test-topic',
        username: 'testuser',
        acl: 'all',
      })
      .expect(400);
    assert.ok(res.body.errors.some((e) => /passphrase/i.test(e)));
  });

  it('POST /api/add-user without confirmPassphrase returns 400', async () => {
    const res = await request(app)
      .post('/api/add-user')
      .send({
        systemName: 'TestSystem',
        topic: 'test-topic',
        username: 'testuser',
        passphrase: 'secret123',
      })
      .expect(400);
    assert.ok(res.body.errors.some((e) => /confirm/i.test(e)));
  });

  it('POST /api/add-user when passphrase and confirmPassphrase do not match returns 400', async () => {
    const res = await request(app)
      .post('/api/add-user')
      .send({
        systemName: 'TestSystem',
        topic: 'test-topic',
        username: 'testuser',
        passphrase: 'secret123',
        confirmPassphrase: 'different456',
      })
      .expect(400);
    assert.ok(res.body.errors.some((e) => /match|do not match/i.test(e)));
  });

  it('POST /api/add-user with valid body (passphrase match) returns 200 or 500', async () => {
    const res = await request(app)
      .post('/api/add-user')
      .send({
        systemName: 'TestSystem',
        topic: 'test-topic',
        username: 'testuser',
        acl: 'all',
        passphrase: 'secret123',
        confirmPassphrase: 'secret123',
      });
    assert.ok([200, 500].includes(res.status), `expected 200 or 500 got ${res.status}`);
    assert.strictEqual(typeof res.body.ok, 'boolean');
    if (res.body.ok && res.body.downloadPath) {
      assert.ok(res.body.downloadPath.startsWith('/api/download/'));
      assert.ok(Array.isArray(res.body.decryptInstructions));
    }
  });

  // ---- Helpers: parsePackFromStdout / buildDecryptInstructions ----
  it('parsePackFromStdout extracts GEN_PACK_FILE and GEN_PACK_NAME', () => {
    const out = 'some log\nGEN_PACK_FILE=MySystem_20260219_1234.enc\nGEN_PACK_NAME=MySystem_20260219_1234\n';
    const { packFile, packName } = parsePackFromStdout(out);
    assert.strictEqual(packFile, 'MySystem_20260219_1234.enc');
    assert.strictEqual(packName, 'MySystem_20260219_1234');
  });

  it('parsePackFromStdout derives packName from packFile when GEN_PACK_NAME missing', () => {
    const out = 'GEN_PACK_FILE=Other_20260219_5678.enc\n';
    const { packFile, packName } = parsePackFromStdout(out);
    assert.strictEqual(packFile, 'Other_20260219_5678.enc');
    assert.strictEqual(packName, 'Other_20260219_5678');
  });

  it('buildDecryptInstructions returns same format as gen.sh', () => {
    const lines = buildDecryptInstructions('Sys_20260219_1200.enc', 'Sys_20260219_1200');
    assert.ok(lines.some((l) => /openssl enc -d -aes-256-cbc/.test(l)));
    assert.ok(lines.some((l) => /tar xzf/.test(l)));
    assert.ok(lines.some((l) => /credentials\.txt|client\.properties|certs|README/.test(l)));
  });

  // ---- Other endpoints: validation ----
  it('POST /api/test-user without username or password returns 400', async () => {
    await request(app).post('/api/test-user').send({}).expect(400);
    const res = await request(app).post('/api/test-user').send({ username: 'u', password: 'p' }).expect(400);
    assert.ok(res.body.errors && res.body.errors.length);
  });

  it('POST /api/remove-user without users returns 400', async () => {
    const res = await request(app).post('/api/remove-user').send({}).expect(400);
    assert.ok(res.body.errors && res.body.errors.some((e) => /users/i.test(e)));
  });

  it('POST /api/change-password without username or newPassword returns 400', async () => {
    await request(app).post('/api/change-password').send({}).expect(400);
  });

  // ---- Create topic: validation ----
  it('POST /api/create-topic without body returns 400', async () => {
    const res = await request(app).post('/api/create-topic').send({}).expect(400);
    assert.ok(Array.isArray(res.body.errors));
    assert.ok(res.body.errors.some((e) => /topic|partitions|replication/i.test(e)));
  });

  it('POST /api/create-topic without topic returns 400', async () => {
    const res = await request(app)
      .post('/api/create-topic')
      .send({ partitions: 1, replicationFactor: 1 })
      .expect(400);
    assert.ok(res.body.errors && res.body.errors.some((e) => /topic/i.test(e)));
  });

  it('POST /api/create-topic with valid body (topic only, broker default partitions/replication) returns 200 or 500', async () => {
    const res = await request(app)
      .post('/api/create-topic')
      .send({ topic: 'test-topic-create' });
    assert.ok([200, 409, 500].includes(res.status), `expected 200, 409 or 500 got ${res.status}`);
    assert.strictEqual(typeof res.body.ok, 'boolean');
    if (res.body.ok) {
      assert.strictEqual(res.body.topic, 'test-topic-create');
    }
  });

  it('GET /api/config returns 200 with gen info', async () => {
    const res = await request(app).get('/api/config').expect(200);
    assert.strictEqual(res.body.ok, true);
    assert.ok(res.body.gen);
  });
});

// ---- Security / vulnerability tests ----
describe('Security: download endpoint', () => {
  const { app, loadConfig } = require('../server/index.js');

  it('GET /api/download with path traversal in param returns 400', async () => {
    const res = await request(app)
      .get('/api/download/' + encodeURIComponent('../etc/passwd'))
      .expect(400);
    assert.ok(res.body.error && /invalid|filename/i.test(res.body.error));
  });

  it('GET /api/download/..%2F..%2Fetc%2Fpasswd returns 400 (encoded path traversal)', async () => {
    const res = await request(app).get('/api/download/..%2F..%2Fetc%2Fpasswd').expect(400);
    assert.ok(res.body.error);
  });

  it('GET /api/download with path segment containing backslash is rejected (400 or 404)', async () => {
    const res = await request(app).get('/api/download/' + encodeURIComponent('..\\..\\file.enc'));
    assert.ok([400, 404].includes(res.status), `expected 400 or 404 got ${res.status}`);
  });

  it('GET /api/download/nonexistent_file_12345.enc returns 404', async () => {
    const res = await request(app).get('/api/download/nonexistent_file_12345.enc').expect(404);
    assert.ok(res.body.error && /not found|file/i.test(res.body.error));
  });

  it('GET /api/download/empty returns 400 or 404 (empty filename)', async () => {
    const res = await request(app).get('/api/download/');
    assert.ok([400, 404].includes(res.status));
  });
});

describe('Security: input validation and limits', () => {
  const { app } = require('../server/index.js');

  it('POST /api/add-user with passphrase as number is rejected or coerced', async () => {
    const res = await request(app)
      .post('/api/add-user')
      .send({
        systemName: 'S',
        topic: 't',
        username: 'u',
        passphrase: 12345,
        confirmPassphrase: 12345,
      });
    assert.ok([400, 500].includes(res.status));
  });

  it('POST /api/add-user with XSS in systemName does not reflect in response as HTML', async () => {
    const res = await request(app)
      .post('/api/add-user')
      .send({
        systemName: '<script>alert(1)</script>',
        topic: 't',
        username: 'u',
        passphrase: 'p',
        confirmPassphrase: 'p',
      });
    if (res.body.errors) {
      const joined = JSON.stringify(res.body);
      assert.ok(!joined.includes('<script>'), 'Response should not reflect unsanitized script');
    }
  });
});

describe('Security: JSON body size limit', () => {
  const { app } = require('../server/index.js');

  it('POST /api/add-user with body > 256kb returns 413 or is rejected', async () => {
    const huge = 'x'.repeat(300 * 1024);
    const res = await request(app)
      .post('/api/add-user')
      .set('Content-Type', 'application/json')
      .send({
        systemName: huge.slice(0, 100),
        topic: 't',
        username: 'u',
        passphrase: huge,
        confirmPassphrase: huge,
      });
    assert.ok([400, 413, 500].includes(res.status), `expected 400/413/500 got ${res.status}`);
  });
});

// ---- Security round 2: filename and parameter edge cases ----
describe('Security round 2: download filename edge cases', () => {
  const { app } = require('../server/index.js');

  it('GET /api/download with very long filename is rejected or 404', async () => {
    const longName = 'a'.repeat(512) + '.enc';
    const res = await request(app).get('/api/download/' + encodeURIComponent(longName));
    assert.ok([400, 404].includes(res.status));
  });

  it('GET /api/download with filename containing only dots/slashes is 400', async () => {
    const res = await request(app).get('/api/download/....enc');
    assert.ok([400, 404].includes(res.status));
  });

  it('GET /api/download with .enc filename but invalid path (double dot) is 400', async () => {
    const res = await request(app).get('/api/download/some..file.enc');
    assert.strictEqual(res.status, 400);
  });
});

// ---- Security round 3: method and route ----
describe('Security round 3: method and route', () => {
  const { app } = require('../server/index.js');

  it('PUT /api/add-user returns 404 (method not allowed)', async () => {
    const res = await request(app).put('/api/add-user').send({});
    assert.strictEqual(res.status, 404);
  });

  it('GET /api/add-user returns 404 (no GET handler)', async () => {
    const res = await request(app).get('/api/add-user');
    assert.strictEqual(res.status, 404);
  });

  it('POST /api/download/nonexistent.enc returns 404 (POST not defined for download)', async () => {
    const res = await request(app).post('/api/download/nonexistent.enc');
    assert.strictEqual(res.status, 404);
  });
});

// ---- Reports & Auth: audit-log, download-history, login-challenge ----
describe('API: audit-log, download-history, login-challenge', () => {
  const { app } = require('../server/index.js');

  it('GET /api/audit-log returns 200 with ok and entries array', async () => {
    const res = await request(app).get('/api/audit-log');
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.body?.ok, true);
    assert.ok(Array.isArray(res.body?.entries));
  });

  it('GET /api/audit-log?from=&to= accepts query params', async () => {
    const res = await request(app).get('/api/audit-log').query({ from: '2025-01-01', to: '2025-12-31' });
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.body?.ok, true);
    assert.ok(Array.isArray(res.body?.entries));
  });

  it('GET /api/download-history returns 200 with ok, days and byDay', async () => {
    const res = await request(app).get('/api/download-history');
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.body?.ok, true);
    assert.ok(Array.isArray(res.body?.days));
    assert.strictEqual(typeof res.body?.byDay, 'object');
  });

  it('GET /api/login-challenge returns 200 with code (string)', async () => {
    const res = await request(app).get('/api/login-challenge');
    assert.strictEqual(res.status, 200);
    assert.ok(res.body && typeof res.body.code === 'string');
  });

  it('GET /api/login-challenge when AUTH_ENABLED=1 returns 6-digit random code', async () => {
    const prev = process.env.AUTH_ENABLED;
    process.env.AUTH_ENABLED = '1';
    try {
      const res = await request(app).get('/api/login-challenge');
      assert.strictEqual(res.status, 200);
      assert.ok(res.body && typeof res.body.code === 'string', 'response has code');
      assert.ok(/^\d{6}$/.test(res.body.code), 'code must be exactly 6 digits, got: ' + JSON.stringify(res.body.code));
    } finally {
      if (prev !== undefined) process.env.AUTH_ENABLED = prev; else delete process.env.AUTH_ENABLED;
    }
  });

  it('POST /api/logout returns 200 (clears session)', async () => {
    const res = await request(app).post('/api/logout');
    assert.strictEqual(res.status, 200);
  });
});

describe('Auth hash (Portal) and OC encrypt', () => {
  const { hashPassword, verifyPassword, isHashedStored } = require('../server/lib/auth-hash');
  const { encrypt, decrypt, getKey } = require('../server/lib/oc-encrypt');

  it('hashPassword + verifyPassword: correct password returns true', () => {
    const h = hashPassword('P@ssw0rd2026');
    assert.strictEqual(typeof h, 'string');
    assert.ok(h.includes(':'));
    assert.strictEqual(isHashedStored(h), true);
    assert.strictEqual(verifyPassword('P@ssw0rd2026', h), true);
  });

  it('verifyPassword: wrong password returns false', () => {
    const h = hashPassword('secret');
    assert.strictEqual(verifyPassword('wrong', h), false);
  });

  it('verifyPassword: plaintext backward compat (no colon format) returns false for wrong', () => {
    assert.strictEqual(verifyPassword('x', 'y'), false);
  });

  it('plaintext stored (short) is not treated as hash', () => {
    assert.strictEqual(isHashedStored('short'), false);
    assert.strictEqual(isHashedStored('plaintext'), false);
  });

  it('OC encrypt/decrypt roundtrip', () => {
    const key = Buffer.alloc(32, 1);
    const keyHex = key.toString('hex');
    const plain = 'ocp@dmin!';
    const enc = encrypt(plain, keyHex);
    assert.ok(enc && enc.startsWith('enc:'));
    const dec = decrypt(enc, keyHex);
    assert.strictEqual(dec, plain);
  });

  it('OC decrypt with wrong key returns null', () => {
    const enc = encrypt('test', 'a'.repeat(64));
    assert.strictEqual(decrypt(enc, 'b'.repeat(64)), null);
  });
});

describe('master.config', () => {
  const { isMasterConfig, expandMasterToLegacy, resolveRuntimeKubeconfigPath } = require('../server/lib/master-config');
  const fixturesDir = path.join(__dirname, 'fixtures');

  it('isMasterConfig recognizes master shape', () => {
    assert.strictEqual(isMasterConfig({ runtimeRoot: '/x', kafka: {}, portal: {} }), true);
    assert.strictEqual(isMasterConfig({ gen: {}, server: {} }), false);
  });

  it('expandMasterToLegacy builds gen.server and inline environments', () => {
    const p = path.join(fixturesDir, 'mini.master.json');
    fs.writeFileSync(p, JSON.stringify({
      runtimeRoot: '/opt/kafka-US',
      kafka: { bootstrapServers: 'b:9092' },
      portal: { port: 3000, auth: { enabled: false, credentialsFile: 'c.json' } },
      environments: {
        enabled: true,
        defaultEnvironmentId: 'dev',
        environments: [{ id: 'dev', sites: [{ ocContext: 'cwdc', namespace: 'ns1' }] }],
      },
    }));
    const legacy = expandMasterToLegacy(JSON.parse(fs.readFileSync(p, 'utf8')), p);
    assert.strictEqual(legacy.gen.baseDir, path.normalize('/opt/kafka-US'));
    assert.strictEqual(legacy.gen.bootstrapServers, 'b:9092');
    assert.strictEqual(legacy.gen.sites.length, 1);
    assert.strictEqual(legacy.gen.sites[0].ocContext, 'cwdc');
    assert.strictEqual(legacy.gen.sites[0].namespace, 'ns1');
    assert.strictEqual(legacy.server.port, 3000);
    assert.ok(legacy.server.environments.inlineData);
    assert.strictEqual(legacy.server.environments.inlineData.environments[0].id, 'dev');
  });

  it('resolveRuntimeKubeconfigPath prefers config when it lists more contexts than config-both', () => {
    const d = fs.mkdtempSync(path.join(os.tmpdir(), 'kube-'));
    const kc = path.join(d, '.kube');
    fs.mkdirSync(kc, { recursive: true });
    fs.writeFileSync(
      path.join(kc, 'config-both'),
      'apiVersion: v1\nkind: Config\ncontexts:\n- name: only-one\n  context:\n    cluster: x\n    user: y\n',
    );
    fs.writeFileSync(
      path.join(kc, 'config'),
      'apiVersion: v1\nkind: Config\ncontexts:\n- name: a\n  context:\n    cluster: c1\n    user: u\n'
        + '- name: b\n  context:\n    cluster: c2\n    user: u\n- name: c\n  context:\n    cluster: c3\n    user: u\n',
    );
    const chosen = resolveRuntimeKubeconfigPath(path.join(kc, 'config-both'), d);
    assert.strictEqual(path.basename(chosen), 'config');
    fs.rmSync(d, { recursive: true, force: true });
  });
});
