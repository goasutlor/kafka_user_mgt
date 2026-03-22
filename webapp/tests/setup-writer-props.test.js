'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  ensureKafkaClientPropertyTemplates,
  DEFAULT_CLIENT_PROPS_FILE,
  DEFAULT_ADMIN_PROPS_FILE,
} = require('../server/lib/setup-writer');

describe('ensureKafkaClientPropertyTemplates', () => {
  it('creates both property files with bootstrap and truststore path', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ku-props-'));
    const r = ensureKafkaClientPropertyTemplates(tmp, 'kafka-dev.example.com:443');
    assert.deepStrictEqual(r.created.sort(), [DEFAULT_ADMIN_PROPS_FILE, DEFAULT_CLIENT_PROPS_FILE].sort());
    assert.strictEqual(r.skipped.length, 0);
    const client = fs.readFileSync(path.join(tmp, 'configs', DEFAULT_CLIENT_PROPS_FILE), 'utf8');
    assert.ok(client.includes('bootstrap.servers=kafka-dev.example.com:443'));
    assert.ok(client.includes('security.protocol=SASL_SSL'));
    const trustPosix = path.posix.join(tmp.replace(/\\/g, '/'), 'configs', 'client.truststore.jks');
    assert.ok(client.includes(`ssl.truststore.location=${trustPosix}`));
  });

  it('skips existing files', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ku-props2-'));
    ensureKafkaClientPropertyTemplates(tmp, 'a:443');
    const r2 = ensureKafkaClientPropertyTemplates(tmp, 'b:999');
    assert.strictEqual(r2.created.length, 0);
    assert.strictEqual(r2.skipped.length, 2);
    const client = fs.readFileSync(path.join(tmp, 'configs', DEFAULT_CLIENT_PROPS_FILE), 'utf8');
    assert.ok(client.includes('bootstrap.servers=a:443'));
  });
});
