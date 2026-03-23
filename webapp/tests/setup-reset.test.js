'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const {
  collectWipePaths,
  verifyPortalCredentialsForWipe,
  performWipe,
  RESET_CONFIRM_PHRASE,
} = require('../server/lib/setup-reset');

describe('setup-reset', () => {
  it('RESET_CONFIRM_PHRASE is stable for UI/API contract', () => {
    assert.strictEqual(RESET_CONFIRM_PHRASE, 'RESET_PORTAL_CONFIG');
  });

  it('verifyPortalCredentialsForWipe + performWipe remove master and credentials', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'reset-'));
    const rt = path.join(root, 'runtime');
    fs.mkdirSync(rt, { recursive: true });
    const masterPath = path.join(root, 'master.config.json');
    const credPath = path.join(root, 'credentials.json');
    fs.writeFileSync(credPath, JSON.stringify({ users: { admin: 's3cret' } }, null, 2), 'utf8');
    fs.writeFileSync(
      masterPath,
      JSON.stringify(
        {
          deploymentInitialized: true,
          runtimeRoot: rt,
          kafka: { bootstrapServers: 'b:9092' },
          portal: {
            port: 3443,
            auth: { enabled: true, credentialsFile: 'credentials.json' },
          },
          oc: { kubeconfig: '{runtimeRoot}/.kube/config', ocPath: '/host/usr/bin' },
        },
        null,
        2,
      ),
      'utf8',
    );
    fs.writeFileSync(path.join(rt, 'environments.json'), '{"environments":[]}', 'utf8');
    fs.writeFileSync(path.join(root, 'audit.log'), 'x\n', 'utf8');

    verifyPortalCredentialsForWipe(masterPath, 'admin', 's3cret');
    const wipe = collectWipePaths(masterPath);
    const { removed } = performWipe(wipe.paths);
    assert.ok(removed.includes(masterPath));
    assert.ok(removed.includes(credPath));
    const envJson = path.join(rt, 'environments.json');
    assert.ok(removed.includes(envJson));
    assert.strictEqual(fs.existsSync(masterPath), false);
    assert.strictEqual(fs.existsSync(credPath), false);
    assert.strictEqual(fs.existsSync(envJson), false);

    fs.rmSync(root, { recursive: true, force: true });
  });
});
