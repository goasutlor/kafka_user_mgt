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

/** Matches Dockerfile KAFKA_TOOLS_BIN parent + symlink name (bind-mount hides /opt/kafka-usermgmt/kafka_*). */
const IMAGE_EMBEDDED_KAFKA_BIN = '/opt/apache-kafka/kafka_2.13-3.6.1/bin';

/**
 * Master config = one JSON per deployment. Detect by runtimeRoot + kafka + portal.
 */
function isMasterConfig(raw) {
  return !!(raw && typeof raw.runtimeRoot === 'string' && raw.kafka && typeof raw.kafka === 'object'
    && raw.portal && typeof raw.portal === 'object');
}

/**
 * When fallbackSites is empty but environments are enabled, mirror the default env's sites into gen.sites
 * so legacy paths (getSitesFromConfig, OC union) see the same OCP targets you configured in Setup.
 */
function deriveFallbackSitesFromEnvironments(envBlock) {
  if (!envBlock || envBlock.enabled !== true || !Array.isArray(envBlock.environments)) return [];
  const list = envBlock.environments.filter((e) => e && e.enabled !== false);
  if (!list.length) return [];
  const defId = envBlock.defaultEnvironmentId;
  const entry = (defId && list.find((e) => e.id === defId)) || list[0];
  if (!entry) return [];
  if (Array.isArray(entry.sites) && entry.sites.length) {
    return entry.sites
      .map((s) => ({
        name: (s.name && String(s.name).trim()) || String(s.ocContext || '').trim() || 'site',
        namespace: String(s.namespace || '').trim(),
        ocContext: String(s.ocContext || '').trim(),
      }))
      .filter((s) => s.namespace && s.ocContext);
  }
  if (entry.namespace && entry.ocContext) {
    const ctx = String(entry.ocContext).trim();
    const ns = String(entry.namespace).trim();
    return [{ name: ctx, namespace: ns, ocContext: ctx }];
  }
  return [];
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
  const kafkaDirRaw = k.clientInstallDir != null && String(k.clientInstallDir).trim()
    ? String(k.clientInstallDir).trim()
    : 'kafka_2.13-3.6.1';
  let kafkaBin = path.isAbsolute(kafkaDirRaw)
    ? path.join(kafkaDirRaw, 'bin')
    : path.join(rt, kafkaDirRaw, 'bin');
  try {
    const topics = path.join(kafkaBin, 'kafka-topics.sh');
    const imageTopics = path.join(IMAGE_EMBEDDED_KAFKA_BIN, 'kafka-topics.sh');
    if (!fs.existsSync(topics) && fs.existsSync(imageTopics)) {
      kafkaBin = IMAGE_EMBEDDED_KAFKA_BIN;
    }
  } catch (_) { /* ignore fs errors */ }

  const gen = {
    scriptPath: path.join(rt, scriptName),
    baseDir: rt,
    downloadDir: path.join(rt, 'user_output'),
    kafkaBin,
    bootstrapServers: k.bootstrapServers || '',
    ocPath: oc.ocPath != null ? oc.ocPath : '/host/usr/bin',
    clientConfig: path.join(rt, 'configs', clientFile),
    adminConfig: path.join(rt, 'configs', adminFile),
    logFile: path.join(rt, 'provisioning.log'),
    k8sSecretName: k.k8sSecretName || 'kafka-server-side-credentials',
    kubeconfigPath: expandRt(kubeTemplate, rt),
    sites: [],
  };

  let sitesArr = Array.isArray(clean.fallbackSites) && clean.fallbackSites.length
    ? [...clean.fallbackSites]
    : (Array.isArray(k.fallbackSites) && k.fallbackSites.length ? [...k.fallbackSites] : []);
  if (!sitesArr.length) {
    sitesArr = deriveFallbackSitesFromEnvironments(envBlock);
  }
  gen.sites = sitesArr;
  if (gen.sites.length) {
    gen.namespace = gen.sites[0].namespace;
    gen.ocContext = gen.sites[0].ocContext;
  } else {
    gen.namespace = '';
    gen.ocContext = '';
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
