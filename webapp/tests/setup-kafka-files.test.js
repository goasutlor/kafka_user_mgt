'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  hasFullKafkaConnection,
  validateKafkaConnectionCompleteness,
  materializeKafkaConnectionFiles,
  DEFAULT_CLIENT_PROPS,
  DEFAULT_ADMIN_PROPS,
} = require('../server/lib/setup-kafka-files');

describe('setup-kafka-files', () => {
  it('hasFullKafkaConnection requires truststore password, PEM or JKS, client SASL, optional admin', () => {
    assert.strictEqual(hasFullKafkaConnection({}), false);
    assert.strictEqual(
      hasFullKafkaConnection({
        kafkaTruststorePassword: 'x',
        kafkaTruststorePem: '-----BEGIN CERTIFICATE-----\nAA\n-----END CERTIFICATE-----',
        kafkaSaslUsername: 'u',
        kafkaSaslPassword: 'p',
      }),
      true,
    );
    assert.strictEqual(
      hasFullKafkaConnection({
        kafkaTruststorePassword: 'x',
        kafkaTruststoreJksBase64: Buffer.alloc(80).toString('base64'),
        kafkaSaslUsername: 'u',
        kafkaSaslPassword: 'p',
        kafkaAdminSameAsClient: false,
      }),
      false,
    );
    assert.strictEqual(
      hasFullKafkaConnection({
        kafkaTruststorePassword: 'x',
        kafkaTruststoreJksBase64: Buffer.alloc(80).toString('base64'),
        kafkaSaslUsername: 'u',
        kafkaSaslPassword: 'p',
        kafkaAdminSameAsClient: false,
        kafkaAdminSaslUsername: 'a',
        kafkaAdminSaslPassword: 'b',
      }),
      true,
    );
  });

  it('validateKafkaConnectionCompleteness throws when partially filled', () => {
    assert.doesNotThrow(() => validateKafkaConnectionCompleteness({}));
    assert.throws(
      () =>
        validateKafkaConnectionCompleteness({
          kafkaTruststorePassword: 'x',
          kafkaSaslUsername: 'u',
        }),
      /Kafka connection/,
    );
  });

  it('materializeKafkaConnectionFiles writes props with escaped Jaas from JKS base64', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ku-kfk-'));
    const jks = Buffer.alloc(100, 7).toString('base64');
    const master = {
      runtimeRoot: tmp,
      kafka: { bootstrapServers: 'broker.example.com:443' },
    };
    const body = {
      kafkaTruststorePassword: 'ts-pass',
      kafkaTruststoreJksBase64: jks,
      kafkaSaslUsername: 'app"user',
      kafkaSaslPassword: 'p\\ass"word',
    };
    const r = materializeKafkaConnectionFiles(body, master);
    assert.strictEqual(r.mode, 'full');
    const client = fs.readFileSync(path.join(tmp, 'configs', DEFAULT_CLIENT_PROPS), 'utf8');
    assert.ok(client.includes('bootstrap.servers=broker.example.com:443'));
    assert.ok(client.includes('username="app\\"user"'));
    assert.ok(client.includes('password="p\\\\ass\\"word"'));
    const admin = fs.readFileSync(path.join(tmp, 'configs', DEFAULT_ADMIN_PROPS), 'utf8');
    assert.ok(admin.includes('username="app\\"user"'));
  });
});
