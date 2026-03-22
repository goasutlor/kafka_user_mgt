'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const TRUSTSTORE_FILENAME = 'client.truststore.jks';
const DEFAULT_CLIENT_PROPS = 'kafka-client.properties';
const DEFAULT_ADMIN_PROPS = 'kafka-client-master.properties';

function escapeForJaasValue(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function truststoreLocationPosix(runtimeRootNorm) {
  const r = String(runtimeRootNorm).replace(/\\/g, '/');
  return path.posix.join(r, 'configs', TRUSTSTORE_FILENAME);
}

/**
 * True when user provided enough to write final truststore + both property files (no CHANGE_ME).
 */
function hasFullKafkaConnection(body) {
  if (!body || typeof body !== 'object') return false;
  const tp = String(body.kafkaTruststorePassword || '').trim();
  const pem = String(body.kafkaTruststorePem || '').trim();
  const b64 = String(body.kafkaTruststoreJksBase64 || '').replace(/\s/g, '');
  const u = String(body.kafkaSaslUsername || '').trim();
  const pw = typeof body.kafkaSaslPassword === 'string' ? body.kafkaSaslPassword : '';
  if (!tp || (!pem && !b64) || !u || !pw) return false;
  if (body.kafkaAdminSameAsClient === false) {
    const au = String(body.kafkaAdminSaslUsername || '').trim();
    const ap = typeof body.kafkaAdminSaslPassword === 'string' ? body.kafkaAdminSaslPassword : '';
    if (!au || !ap) return false;
  }
  return true;
}

function anyKafkaConnectionFieldTouched(body) {
  if (!body || typeof body !== 'object') return false;
  if (String(body.kafkaTruststorePassword || '').trim()) return true;
  if (String(body.kafkaTruststorePem || '').trim()) return true;
  if (String(body.kafkaTruststoreJksBase64 || '').replace(/\s/g, '')) return true;
  if (String(body.kafkaSaslUsername || '').trim()) return true;
  if (typeof body.kafkaSaslPassword === 'string' && body.kafkaSaslPassword) return true;
  if (body.kafkaAdminSameAsClient === false) {
    if (String(body.kafkaAdminSaslUsername || '').trim()) return true;
    if (typeof body.kafkaAdminSaslPassword === 'string' && body.kafkaAdminSaslPassword) return true;
  }
  return false;
}

function validateKafkaConnectionCompleteness(body) {
  if (!anyKafkaConnectionFieldTouched(body)) return;
  if (!hasFullKafkaConnection(body)) {
    throw new Error(
      'Kafka connection: fill all of truststore password, PEM or JKS (base64), SASL username/password, '
        + 'or leave the whole block empty to use template files only.',
    );
  }
}

function buildPropertiesContent(bootstrap, truststorePosix, trustPass, saslUser, saslPass, headerTitle) {
  return [
    `# ${headerTitle}`,
    '# Written by portal setup — future edits: change files under the runtime mount configs/.',
    '',
    `bootstrap.servers=${bootstrap}`,
    'security.protocol=SASL_SSL',
    'sasl.mechanism=PLAIN',
    'client.dns.lookup=use_all_dns_ips',
    `ssl.truststore.location=${truststorePosix}`,
    `ssl.truststore.password=${trustPass}`,
    'ssl.truststore.type=JKS',
    `sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${escapeForJaasValue(saslUser)}" password="${escapeForJaasValue(saslPass)}";`,
    'acks=all',
    '',
  ].join('\n');
}

function atomicWriteText(filePath, content) {
  const tmp = filePath + '.tmp';
  fs.writeFileSync(tmp, content, 'utf8');
  fs.renameSync(tmp, filePath);
}

function writeTruststoreFromJksBase64(base64, destPath) {
  const buf = Buffer.from(String(base64).replace(/\s/g, ''), 'base64');
  if (buf.length < 64) {
    throw new Error('Truststore JKS (base64) decodes to very little data — check the paste');
  }
  const tmp = destPath + '.tmp';
  fs.writeFileSync(tmp, buf);
  fs.renameSync(tmp, destPath);
}

function extractPemCertificates(pemString) {
  const pem = String(pemString).trim();
  const re = /-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g;
  return pem.match(re) || [];
}

function writeTruststoreFromPem(pemString, destPath, storePassword) {
  const certs = extractPemCertificates(pemString);
  if (!certs.length) {
    throw new Error('Truststore PEM must contain at least one -----BEGIN CERTIFICATE----- block');
  }
  const dir = path.dirname(destPath);
  fs.mkdirSync(dir, { recursive: true });
  try {
    fs.unlinkSync(destPath);
  } catch (_) { /* none */ }

  for (let i = 0; i < certs.length; i++) {
    const tmpPem = `${destPath}.part${i}.pem`;
    fs.writeFileSync(tmpPem, certs[i], 'utf8');
    const args = [
      '-importcert',
      '-noprompt',
      '-alias',
      `ca${i}`,
      '-file',
      tmpPem,
      '-keystore',
      destPath,
      '-storepass',
      storePassword,
      '-storetype',
      'JKS',
    ];
    const r = spawnSync('keytool', args, { encoding: 'utf8', timeout: 120000 });
    try {
      fs.unlinkSync(tmpPem);
    } catch (_) {}
    if (r.status !== 0) {
      try {
        fs.unlinkSync(destPath);
      } catch (_) {}
      const msg = ((r.stderr || r.stdout || '') + '').trim().slice(0, 600);
      throw new Error(`keytool failed importing certificate ${i + 1}: ${msg || `exit ${r.status}`}`);
    }
  }
}

/**
 * Write client.truststore.jks + kafka-client*.properties from wizard body. Overwrites when re-saving.
 * @returns {{ mode: 'full', files: string[] } | { mode: 'skipped' }}
 */
function materializeKafkaConnectionFiles(body, master) {
  if (!hasFullKafkaConnection(body)) {
    return { mode: 'skipped' };
  }
  const rt = master && master.runtimeRoot;
  const bs = master && master.kafka && master.kafka.bootstrapServers;
  if (!String(rt || '').trim() || !String(bs || '').trim()) {
    throw new Error('runtimeRoot and kafka.bootstrapServers are required');
  }

  const root = path.isAbsolute(rt) ? path.normalize(rt) : path.resolve(rt);
  const configsDir = path.join(root, 'configs');
  fs.mkdirSync(configsDir, { recursive: true });

  const destJks = path.join(configsDir, TRUSTSTORE_FILENAME);
  const storePass = String(body.kafkaTruststorePassword).trim();
  const pem = String(body.kafkaTruststorePem || '').trim();
  const b64 = String(body.kafkaTruststoreJksBase64 || '').replace(/\s/g, '');

  if (pem && b64) {
    throw new Error('Provide either PEM certificate chain OR JKS base64, not both');
  }
  if (pem) {
    writeTruststoreFromPem(pem, destJks, storePass);
  } else {
    writeTruststoreFromJksBase64(b64, destJks);
  }

  const posixTrust = truststoreLocationPosix(root);
  const clientUser = String(body.kafkaSaslUsername).trim();
  const clientPass = body.kafkaSaslPassword;
  const adminSame = body.kafkaAdminSameAsClient !== false;
  let adminUser = clientUser;
  let adminPass = clientPass;
  if (!adminSame) {
    adminUser = String(body.kafkaAdminSaslUsername || '').trim();
    adminPass = body.kafkaAdminSaslPassword;
  }

  atomicWriteText(
    path.join(configsDir, DEFAULT_CLIENT_PROPS),
    buildPropertiesContent(bs, posixTrust, storePass, clientUser, clientPass, 'Kafka client (application user)'),
  );
  atomicWriteText(
    path.join(configsDir, DEFAULT_ADMIN_PROPS),
    buildPropertiesContent(bs, posixTrust, storePass, adminUser, adminPass, 'Kafka admin client (operator)'),
  );

  if (process.platform !== 'win32') {
    try {
      fs.chmodSync(path.join(configsDir, DEFAULT_CLIENT_PROPS), 0o600);
      fs.chmodSync(path.join(configsDir, DEFAULT_ADMIN_PROPS), 0o600);
      fs.chmodSync(destJks, 0o600);
    } catch (_) { /* ignore */ }
  }

  return {
    mode: 'full',
    files: [TRUSTSTORE_FILENAME, DEFAULT_CLIENT_PROPS, DEFAULT_ADMIN_PROPS],
  };
}

module.exports = {
  TRUSTSTORE_FILENAME,
  DEFAULT_CLIENT_PROPS,
  DEFAULT_ADMIN_PROPS,
  hasFullKafkaConnection,
  anyKafkaConnectionFieldTouched,
  validateKafkaConnectionCompleteness,
  materializeKafkaConnectionFiles,
  truststoreLocationPosix,
};
