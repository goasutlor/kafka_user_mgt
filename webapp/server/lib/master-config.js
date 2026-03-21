'use strict';

const fs = require('fs');
const path = require('path');

function stripUnderscoreKeys(obj) {
  if (!obj || typeof obj !== 'object') return obj;
  if (Array.isArray(obj)) return obj.map(stripUnderscoreKeys);
  const out = {};
  Object.keys(obj).forEach((k) => {
    if (k.startsWith('_')) return;
    out[k] = stripUnderscoreKeys(obj[k]);
  });
  return out;
}

function expandRt(str, runtimeRoot) {
  if (typeof str !== 'string') return str;
  return str.split('{runtimeRoot}').join(runtimeRoot);
}

/**
 * Master config = one JSON per deployment. Detect by runtimeRoot + kafka + portal.
 */
function isMasterConfig(raw) {
  return !!(raw && typeof raw.runtimeRoot === 'string' && raw.kafka && typeof raw.kafka === 'object'
    && raw.portal && typeof raw.portal === 'object');
}

/**
 * Expand master JSON → legacy { gen, server } used by the rest of the app.
 * @param {object} raw - parsed JSON
 * @param {string} masterFileAbsPath - absolute path to the master file (for resolving relative credentials path)
 */
function expandMasterToLegacy(raw, masterFileAbsPath) {
  const clean = stripUnderscoreKeys(raw);
  const masterDir = path.dirname(masterFileAbsPath);
  const rt = path.normalize(expandRt(clean.runtimeRoot, clean.runtimeRoot));
  const k = clean.kafka || {};
  const oc = clean.oc || {};
  const portal = clean.portal || {};
  const envBlock = clean.environments;

  const scriptName = k.scriptName || 'gen.sh';
  const clientFile = k.clientPropertiesFile || 'kafka-client.properties';
  const adminFile = k.adminPropertiesFile || 'kafka-client-master.properties';
  const kubeTemplate = oc.kubeconfig || '{runtimeRoot}/.kube/config-both';
  const kafkaDir = k.clientInstallDir || 'kafka_2.13-3.6.1';

  const gen = {
    scriptPath: path.join(rt, scriptName),
    baseDir: rt,
    downloadDir: path.join(rt, 'user_output'),
    kafkaBin: path.join(rt, kafkaDir, 'bin'),
    bootstrapServers: k.bootstrapServers || '',
    ocPath: oc.ocPath != null ? oc.ocPath : '/host/usr/bin',
    clientConfig: path.join(rt, 'configs', clientFile),
    adminConfig: path.join(rt, 'configs', adminFile),
    logFile: path.join(rt, 'provisioning.log'),
    k8sSecretName: k.k8sSecretName || 'kafka-server-side-credentials',
    kubeconfigPath: expandRt(kubeTemplate, rt),
    sites: Array.isArray(clean.fallbackSites) ? clean.fallbackSites : (Array.isArray(k.fallbackSites) ? k.fallbackSites : []),
  };

  if (!gen.sites.length) {
    gen.namespace = 'esb-prod-cwdc';
    gen.ocContext = 'cwdc';
  }

  if (oc.loginServers && typeof oc.loginServers === 'object') {
    gen.ocLoginServers = { ...oc.loginServers };
  }
  if (oc.autoLogin === true) gen.ocAutoLogin = true;
  if (oc.loginTokens && typeof oc.loginTokens === 'object') {
    gen.ocLoginTokens = { ...oc.loginTokens };
  }

  const auth = portal.auth || {};
  const credName = auth.credentialsFile || auth.secretsFile || 'credentials.json';

  const server = {
    port: portal.port != null ? portal.port : 3443,
    environments: {
      enabled: false,
      file: 'environments.json',
      inlineData: null,
      derivedSyncPath: null,
    },
    auth: {
      enabled: auth.enabled === true,
      secretsFile: credName,
    },
    https: portal.https || { enabled: false, keyPath: '/app/ssl/server.key', certPath: '/app/ssl/server.crt' },
  };

  if (envBlock && typeof envBlock === 'object') {
    server.environments.enabled = envBlock.enabled === true;
    const items = envBlock.environments || envBlock.items;
    server.environments.inlineData = {
      enabled: envBlock.enabled !== false,
      defaultEnvironmentId: envBlock.defaultEnvironmentId || null,
      environments: Array.isArray(items) ? items : [],
    };
  }

  return { gen, server };
}

/** Write environments.json under gen.baseDir so gen.sh (GEN_ENVIRONMENTS_JSON) matches the portal. */
function syncEnvironmentsDerivedFile(cfg) {
  const sec = cfg.server?.environments;
  if (!sec || sec.enabled !== true || !sec.inlineData) return;
  const baseDir = cfg.gen?.baseDir;
  if (!baseDir) return;
  const data = sec.inlineData;
  const list = Array.isArray(data.environments) ? data.environments : [];
  if (list.length === 0) return;
  const payload = {
    enabled: data.enabled !== false,
    defaultEnvironmentId: data.defaultEnvironmentId || (list[0] && list[0].id) || null,
    environments: list,
  };
  const outPath = path.join(baseDir, 'environments.json');
  try {
    if (!fs.existsSync(baseDir)) fs.mkdirSync(baseDir, { recursive: true });
    const tmp = outPath + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(payload, null, 2), 'utf8');
    fs.renameSync(tmp, outPath);
    sec.derivedSyncPath = outPath;
  } catch (e) {
    console.warn('[config] could not sync environments.json to runtime:', e.message);
  }
}

module.exports = {
  isMasterConfig,
  expandMasterToLegacy,
  syncEnvironmentsDerivedFile,
};
