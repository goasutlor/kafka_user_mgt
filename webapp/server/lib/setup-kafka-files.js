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

/** Safe segment for kafka-client(-master)-{id}.properties filenames. */
function sanitizeKafkaEnvIdForFile(id) {
  const s = String(id || '').trim().replace(/[^a-zA-Z0-9_-]/g, '');
  return s || null;
}

function truststoreLocationPosix(runtimeRootNorm) {
  const r = String(runtimeRootNorm).replace(/\\/g, '/');
  return path.posix.join(r, 'configs', TRUSTSTORE_FILENAME);
}

function pathToPosix(absPath) {
  return path.normalize(String(absPath || '')).replace(/\\/g, '/');
}

/**
 * Absolute path to JKS when user places file on runtime mount (optional relative path under runtimeRoot).
 */
function getTruststoreAbsolutePathForWizard(body, runtimeRootNorm) {
  const root = path.isAbsolute(runtimeRootNorm) ? path.normalize(runtimeRootNorm) : path.resolve(runtimeRootNorm);
  const raw = String((body && body.kafkaTruststorePath) || '').trim();
  if (!raw) {
    return path.join(root, 'configs', TRUSTSTORE_FILENAME);
  }
  if (path.isAbsolute(raw)) {
    return path.normalize(raw);
  }
  return path.normalize(path.join(root, raw.replace(/^[/\\]+/, '')));
}

function truststoreUsesExistingFile(body) {
  return body && body.kafkaTruststoreUseExistingFile === true;
}

/**
 * True when user provided enough to write final property files (and truststore if pasted/generated).
 */
function hasFullKafkaConnection(body) {
  if (!body || typeof body !== 'object') return false;
  const tp = String(body.kafkaTruststorePassword || '').trim();
  const pem = String(body.kafkaTruststorePem || '').trim();
  const b64 = String(body.kafkaTruststoreJksBase64 || '').replace(/\s/g, '');
  const u = String(body.kafkaSaslUsername || '').trim();
  const pw = typeof body.kafkaSaslPassword === 'string' ? body.kafkaSaslPassword : '';
  const useFile = truststoreUsesExistingFile(body);
  if (!tp || !u || !pw) return false;
  if (useFile) {
    if (pem || b64) return false;
  } else {
    if (!pem && !b64) return false;
  }
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
  if (String(body.kafkaTruststorePath || '').trim()) return true;
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
  if (truststoreUsesExistingFile(body)) {
    if (String(body.kafkaTruststorePem || '').trim() || String(body.kafkaTruststoreJksBase64 || '').replace(/\s/g, '')) {
      throw new Error('Kafka connection: choose either truststore file on server or paste PEM/base64, not both.');
    }
  }
  if (!hasFullKafkaConnection(body)) {
    throw new Error(
      'Kafka connection: fill truststore password, SASL username/password, and either (1) place JKS on mount + select that mode, '
        + 'or (2) PEM or JKS base64 — or leave the whole block empty for templates only.',
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

/** @returns {{ ok: boolean, message?: string }} */
function verifyTruststoreWithKeytool(jksPath, storePassword) {
  const pass = String(storePassword || '');
  if (!jksPath || !fs.existsSync(jksPath)) {
    return { ok: false, message: 'Truststore file not found' };
  }
  const r = spawnSync(
    'keytool',
    ['-list', '-keystore', jksPath, '-storepass', pass, '-storetype', 'JKS'],
    { encoding: 'utf8', timeout: 30000 },
  );
  if (r.error) {
    return { ok: false, message: r.error.message || 'keytool not available' };
  }
  if (r.status === 0) {
    return { ok: true };
  }
  const msg = ((r.stderr || r.stdout || '') + '').trim().slice(0, 400);
  return { ok: false, message: msg || `keytool exit ${r.status}` };
}

/**
 * Write kafka-client*.properties; optionally write client.truststore.jks from PEM/base64.
 * @returns {{ mode: 'full', files: string[], truststoreSource: 'existing' | 'written' } | { mode: 'skipped' }}
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

  const storePass = String(body.kafkaTruststorePassword).trim();
  const pem = String(body.kafkaTruststorePem || '').trim();
  const b64 = String(body.kafkaTruststoreJksBase64 || '').replace(/\s/g, '');
  const useExisting = truststoreUsesExistingFile(body);

  let destJks;
  let posixTrust;
  let truststoreSource;

  if (useExisting) {
    if (pem || b64) {
      throw new Error('Truststore: file-on-server mode cannot be combined with PEM or base64');
    }
    destJks = getTruststoreAbsolutePathForWizard(body, root);
    if (!fs.existsSync(destJks)) {
      throw new Error(
        `Truststore file not found at ${destJks} — copy your .jks onto the runtime mount (e.g. under configs/) before Save or Verify.`,
      );
    }
    posixTrust = pathToPosix(destJks);
    truststoreSource = 'existing';
  } else {
    if (pem && b64) {
      throw new Error('Provide either PEM certificate chain OR JKS base64, not both');
    }
    destJks = path.join(configsDir, TRUSTSTORE_FILENAME);
    if (pem) {
      writeTruststoreFromPem(pem, destJks, storePass);
    } else {
      writeTruststoreFromJksBase64(b64, destJks);
    }
    posixTrust = truststoreLocationPosix(root);
    truststoreSource = 'written';
  }

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

  const files = truststoreSource === 'written'
    ? [TRUSTSTORE_FILENAME, DEFAULT_CLIENT_PROPS, DEFAULT_ADMIN_PROPS]
    : [DEFAULT_CLIENT_PROPS, DEFAULT_ADMIN_PROPS];

  const envBlock = master && master.environments;
  const defaultBs = String(bs || '').trim();
  if (envBlock && envBlock.enabled === true && Array.isArray(envBlock.environments) && defaultBs) {
    for (const e of envBlock.environments) {
      const sid = sanitizeKafkaEnvIdForFile(e && e.id);
      if (!sid) continue;
      const envBs = (e && typeof e.bootstrapServers === 'string' && e.bootstrapServers.trim())
        ? e.bootstrapServers.trim()
        : defaultBs;
      if (!envBs) continue;
      const cname = `kafka-client-${sid}.properties`;
      const aname = `kafka-client-master-${sid}.properties`;
      atomicWriteText(
        path.join(configsDir, cname),
        buildPropertiesContent(envBs, posixTrust, storePass, clientUser, clientPass, `Kafka client (${sid})`),
      );
      atomicWriteText(
        path.join(configsDir, aname),
        buildPropertiesContent(envBs, posixTrust, storePass, adminUser, adminPass, `Kafka admin client (${sid})`),
      );
      files.push(cname, aname);
      if (process.platform !== 'win32') {
        try {
          fs.chmodSync(path.join(configsDir, cname), 0o600);
          fs.chmodSync(path.join(configsDir, aname), 0o600);
        } catch (_) { /* ignore */ }
      }
    }
  }

  if (process.platform !== 'win32') {
    try {
      fs.chmodSync(path.join(configsDir, DEFAULT_CLIENT_PROPS), 0o600);
      fs.chmodSync(path.join(configsDir, DEFAULT_ADMIN_PROPS), 0o600);
      if (truststoreSource === 'written') {
        fs.chmodSync(destJks, 0o600);
      }
    } catch (_) { /* ignore */ }
  }

  return {
    mode: 'full',
    files,
    truststoreSource,
    truststorePath: destJks,
  };
}

module.exports = {
  TRUSTSTORE_FILENAME,
  DEFAULT_CLIENT_PROPS,
  DEFAULT_ADMIN_PROPS,
  sanitizeKafkaEnvIdForFile,
  hasFullKafkaConnection,
  anyKafkaConnectionFieldTouched,
  validateKafkaConnectionCompleteness,
  materializeKafkaConnectionFiles,
  truststoreLocationPosix,
  getTruststoreAbsolutePathForWizard,
  verifyTruststoreWithKeytool,
  truststoreUsesExistingFile,
};
