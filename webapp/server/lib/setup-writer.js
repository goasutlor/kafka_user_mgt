'use strict';

const fs = require('fs');
const path = require('path');
const {
  hasFullKafkaConnection,
  materializeKafkaConnectionFiles,
  sanitizeKafkaEnvIdForFile,
} = require('./setup-kafka-files');

/** Fixed names in master.config and on disk under {runtimeRoot}/configs/ */
const DEFAULT_CLIENT_PROPS_FILE = 'kafka-client.properties';
const DEFAULT_ADMIN_PROPS_FILE = 'kafka-client-master.properties';

/**
 * Ensure SASL_SSL client templates exist under runtimeRoot/configs (do not overwrite).
 * Truststore cannot be generated for org brokers — user copies .jks and edits CHANGE_ME.
 * @returns {{ created: string[], skipped: string[] }}
 */
function ensureKafkaClientPropertyTemplates(runtimeRoot, bootstrapServers) {
  const boot = String(bootstrapServers || '').trim();
  if (!boot) return { created: [], skipped: [] };

  const root = path.isAbsolute(runtimeRoot)
    ? path.normalize(runtimeRoot)
    : path.resolve(runtimeRoot);
  const configsDir = path.join(root, 'configs');
  if (!fs.existsSync(configsDir)) {
    fs.mkdirSync(configsDir, { recursive: true });
  }

  const truststoreInContainer = path.posix.join(
    root.replace(/\\/g, '/'),
    'configs',
    'client.truststore.jks',
  );

  const lines = (roleLine) =>
    [
      `# ${roleLine}`,
      '# Created by portal setup (first save) or gen.sh GEN_MODE=8 — existing files are never overwritten.',
      '# EDIT: ssl.truststore.password and sasl.jaas.config (username/password).',
      '# Truststore: copy your org CA bundle as client.truststore.jks into configs/ (path below).',
      '# Cannot auto-generate a truststore that trusts your corporate brokers without your CA.',
      '',
      `bootstrap.servers=${boot}`,
      'security.protocol=SASL_SSL',
      'sasl.mechanism=PLAIN',
      'client.dns.lookup=use_all_dns_ips',
      `ssl.truststore.location=${truststoreInContainer}`,
      'ssl.truststore.password=CHANGE_ME',
      'ssl.truststore.type=JKS',
      'sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="CHANGE_ME" password="CHANGE_ME";',
      'acks=all',
      '',
    ].join('\n');

  const pairs = [
    [DEFAULT_CLIENT_PROPS_FILE, 'Kafka client (application user)'],
    [DEFAULT_ADMIN_PROPS_FILE, 'Kafka admin client (operator user)'],
  ];
  const created = [];
  const skipped = [];
  for (const [fname, role] of pairs) {
    const dest = path.join(configsDir, fname);
    if (fs.existsSync(dest)) {
      skipped.push(fname);
      continue;
    }
    const tmp = dest + '.tmp';
    fs.writeFileSync(tmp, lines(role), 'utf8');
    fs.renameSync(tmp, dest);
    created.push(fname);
  }
  return { created, skipped };
}

/**
 * When environments.enabled: create kafka-client-{id}.properties + kafka-client-master-{id}.properties
 * (templates with CHANGE_ME) if missing — same as default templates but per-env bootstrap.
 * @returns {{ created: string[], skipped: string[] }}
 */
function ensureKafkaEnvPropertyTemplatesFromMaster(master) {
  const envBlock = master && master.environments;
  if (!envBlock || envBlock.enabled !== true || !Array.isArray(envBlock.environments)) {
    return { created: [], skipped: [] };
  }
  const defaultBs = master.kafka && master.kafka.bootstrapServers ? String(master.kafka.bootstrapServers).trim() : '';
  const rt = master.runtimeRoot;
  if (!String(rt || '').trim() || !defaultBs) {
    return { created: [], skipped: [] };
  }

  const root = path.isAbsolute(rt) ? path.normalize(rt) : path.resolve(rt);
  const configsDir = path.join(root, 'configs');
  if (!fs.existsSync(configsDir)) {
    fs.mkdirSync(configsDir, { recursive: true });
  }

  const truststoreInContainer = path.posix.join(
    root.replace(/\\/g, '/'),
    'configs',
    'client.truststore.jks',
  );

  const lines = (roleLine, boot) =>
    [
      `# ${roleLine}`,
      '# Created by portal setup — per-environment template; existing files are never overwritten.',
      '# EDIT: ssl.truststore.password and sasl.jaas.config (username/password).',
      '# Truststore: copy client.truststore.jks into configs/ (path below).',
      '',
      `bootstrap.servers=${boot}`,
      'security.protocol=SASL_SSL',
      'sasl.mechanism=PLAIN',
      'client.dns.lookup=use_all_dns_ips',
      `ssl.truststore.location=${truststoreInContainer}`,
      'ssl.truststore.password=CHANGE_ME',
      'ssl.truststore.type=JKS',
      'sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="CHANGE_ME" password="CHANGE_ME";',
      'acks=all',
      '',
    ].join('\n');

  const created = [];
  const skipped = [];
  for (const e of envBlock.environments) {
    const sid = sanitizeKafkaEnvIdForFile(e && e.id);
    if (!sid) continue;
    const boot = (e && typeof e.bootstrapServers === 'string' && e.bootstrapServers.trim())
      ? e.bootstrapServers.trim()
      : defaultBs;
    const pairs = [
      [`kafka-client-${sid}.properties`, `Kafka client (${sid})`],
      [`kafka-client-master-${sid}.properties`, `Kafka admin client (${sid})`],
    ];
    for (const [fname, role] of pairs) {
      const dest = path.join(configsDir, fname);
      if (fs.existsSync(dest)) {
        skipped.push(fname);
        continue;
      }
      const tmp = dest + '.tmp';
      fs.writeFileSync(tmp, lines(role, boot), 'utf8');
      fs.renameSync(tmp, dest);
      created.push(fname);
    }
  }
  return { created, skipped };
}

function atomicWriteJson(filePath, obj) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  const tmp = filePath + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), 'utf8');
  fs.renameSync(tmp, filePath);
}

/**
 * @param {string} configAbsPath - master.config.json absolute path
 * @returns {{ ok: boolean, error?: string }}
 */
function configDirectoryWritable(configAbsPath) {
  const dir = path.dirname(configAbsPath);
  try {
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.accessSync(dir, fs.constants.W_OK);
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

/**
 * @param {object} body
 * @returns {Array<{ name: string, namespace: string, ocContext: string, apiServer: string, loginUser?: string, loginPassword?: string }>|null}
 */
/** Merge optional per-environment bootstrap overrides from wizard into env entries (Web + environments.json). */
function mergeEnvironmentBootstrapOverrides(envList, overrides) {
  if (!Array.isArray(envList) || !overrides || typeof overrides !== 'object') return envList;
  for (const item of envList) {
    if (!item || !item.id) continue;
    const v = overrides[item.id];
    if (typeof v === 'string' && v.trim()) {
      item.bootstrapServers = v.trim();
    }
  }
  return envList;
}

function normalizeOcSitesFromBody(body) {
  const raw = body.ocSites;
  if (!Array.isArray(raw) || raw.length === 0) return null;
  const topo = body.ocTopology === 'dual' ? 'dual' : 'single';
  const sites = [];
  for (let i = 0; i < raw.length; i++) {
    const s = raw[i] || {};
    const ocContext = String(s.ocContext || '').trim();
    const namespace = String(s.namespace || '').trim();
    const apiServer = String(s.apiServer || s.ocLoginServer || '').trim();
    const name = String(s.name || ocContext || `site${i + 1}`).trim();
    if (!ocContext || !namespace) {
      throw new Error(`OCP site ${i + 1}: ocContext and namespace are required`);
    }
    sites.push({
      name,
      namespace,
      ocContext,
      apiServer,
      loginUser: s.loginUser != null ? String(s.loginUser).trim() : '',
      loginPassword: typeof s.loginPassword === 'string' ? s.loginPassword : '',
    });
  }
  if (topo === 'dual') {
    if (sites.length < 2) {
      throw new Error('Dual-cluster (cross-region) topology requires at least two OCP sites');
    }
  }
  // Single topology may list multiple sites (same cluster: one API, many namespace+context pairs).
  const ctxs = sites.map((s) => s.ocContext);
  if (new Set(ctxs).size !== ctxs.length) {
    throw new Error('Each OCP site must use a distinct ocContext name');
  }
  return sites;
}

function buildOcLoginServersFromSites(sites, body) {
  const servers = {};
  for (const s of sites) {
    if (s.apiServer) servers[s.ocContext] = s.apiServer;
  }
  if (body.ocLoginServers && typeof body.ocLoginServers === 'object') {
    Object.assign(servers, body.ocLoginServers);
  }
  return servers;
}

/**
 * Build master + credentials from setup wizard body (no secrets in master file).
 */
function buildFilesFromSetupBody(body, configAbsPath) {
  const masterDir = path.dirname(configAbsPath);
  if (!String(body.runtimeRoot || '').trim() || !String(body.kafkaBootstrap || '').trim()) {
    throw new Error('runtimeRoot and kafkaBootstrap are required');
  }
  const rt = String(body.runtimeRoot || '/opt/kafka-usermgmt').trim();
  const credFileName = String(body.credentialsFile || 'credentials.json').trim() || 'credentials.json';

  const environments = body.environments && typeof body.environments === 'object'
    ? body.environments
    : {
      enabled: body.environmentsEnabled === true,
      defaultEnvironmentId: String(body.defaultEnvironmentId || 'dev').trim(),
      environments: Array.isArray(body.environmentItems) ? body.environmentItems : [],
    };

  const ocSitesNorm = normalizeOcSitesFromBody(body);

  let fallbackSites = Array.isArray(body.fallbackSites) ? [...body.fallbackSites] : [];
  let ocLoginServers = body.ocLoginServers && typeof body.ocLoginServers === 'object'
    ? { ...body.ocLoginServers }
    : {};

  if (ocSitesNorm) {
    fallbackSites = ocSitesNorm.map(({ name, namespace, ocContext }) => ({ name, namespace, ocContext }));
    ocLoginServers = buildOcLoginServersFromSites(ocSitesNorm, body);
  } else {
    if (!Object.keys(ocLoginServers).length && body.ocLoginServer && body.ocLoginContext) {
      const ctx = String(body.ocLoginContext).trim();
      ocLoginServers[ctx] = String(body.ocLoginServer).trim();
    }
    if (!fallbackSites.length && body.singleNamespace && body.ocLoginContext) {
      const ctx = String(body.ocLoginContext).trim();
      fallbackSites = [{ name: ctx, namespace: String(body.singleNamespace).trim(), ocContext: ctx }];
    }
  }

  const master = {
    deploymentInitialized: true,
    runtimeRoot: rt,
    kafka: {
      scriptName: String(body.scriptName || 'gen.sh').trim(),
      bootstrapServers: String(body.kafkaBootstrap || '').trim(),
      k8sSecretName: String(body.k8sSecretName || 'kafka-server-side-credentials').trim(),
      clientPropertiesFile: DEFAULT_CLIENT_PROPS_FILE,
      adminPropertiesFile: DEFAULT_ADMIN_PROPS_FILE,
    },
    oc: {
      ocPath: String(body.ocPath != null ? body.ocPath : '/host/usr/bin').trim(),
      kubeconfig: String(body.kubeconfig || '{runtimeRoot}/.kube/config').trim(),
      autoLogin: body.ocAutoLogin === true,
      loginServers: ocLoginServers,
    },
    portal: {
      port: Math.min(65535, Math.max(1, parseInt(body.portalPort, 10) || 3443)),
      auth: {
        enabled: body.authEnabled === true,
        credentialsFile: credFileName,
      },
      https: {
        enabled: body.httpsEnabled === true,
        keyPath: String(body.httpsKeyPath || '/app/ssl/server.key').trim(),
        certPath: String(body.httpsCertPath || '/app/ssl/server.crt').trim(),
      },
    },
  };

  if (environments.enabled === true) {
    const envListRaw = Array.isArray(environments.environments) ? environments.environments : [];
    const envList = envListRaw.map((e) => ({ ...e }));
    mergeEnvironmentBootstrapOverrides(envList, body.environmentBootstrapOverrides);
    master.environments = {
      enabled: true,
      defaultEnvironmentId: environments.defaultEnvironmentId || 'dev',
      environments: envList,
    };
  } else {
    master.environments = { enabled: false };
  }

  if (fallbackSites.length > 0) {
    master.fallbackSites = fallbackSites;
  }

  // Per-environment OCP targets may carry apiServer; merge into loginServers for OC auto-login / verify.
  {
    const ls = { ...(master.oc.loginServers || {}) };
    if (master.environments && master.environments.enabled && Array.isArray(master.environments.environments)) {
      for (const e of master.environments.environments) {
        if (!Array.isArray(e.sites)) continue;
        for (const s of e.sites) {
          const api = String(s.apiServer || '').trim();
          const ctx = String(s.ocContext || '').trim();
          if (ctx && api) ls[ctx] = api;
        }
      }
    }
    master.oc.loginServers = ls;
  }

  if (master.oc.autoLogin === true) {
    const hasServers = master.oc.loginServers && typeof master.oc.loginServers === 'object'
      && Object.keys(master.oc.loginServers).length > 0;
    if (!hasServers) {
      throw new Error('OC auto-login requires an API URL for each cluster (loginServers / site apiServer fields)');
    }
  }

  const users = {};
  const adminUser = String(body.adminUser || '').trim();
  const adminPassword = body.adminPassword;
  if (master.portal.auth.enabled) {
    if (!adminUser || typeof adminPassword !== 'string' || !adminPassword) {
      throw new Error('When portal auth is enabled, adminUser and adminPassword are required');
    }
    users[adminUser] = adminPassword;
  }

  const credentials = {
    users,
  };

  const credMode = body.ocCredentialMode === 'per_cluster' ? 'per_cluster' : 'shared';

  if (master.oc.autoLogin) {
    if (credMode === 'per_cluster') {
      if (!ocSitesNorm || !ocSitesNorm.length) {
        throw new Error('Per-cluster OC credentials require structured OCP sites (ocSites array with user/password per site)');
      }
      const loginCredentials = {};
      for (const s of ocSitesNorm) {
        if (!s.loginUser || !s.loginPassword) {
          throw new Error(`Per-cluster OC credentials: user and password required for context "${s.ocContext}"`);
        }
        loginCredentials[s.ocContext] = { user: s.loginUser, password: s.loginPassword };
      }
      credentials.oc = {
        ocAutoLogin: true,
        loginCredentials,
        loginServers: {},
        loginTokens: {},
      };
    } else {
      const u = String(body.ocLoginUser || '').trim();
      const p = body.ocLoginPassword;
      if (!u || typeof p !== 'string' || !p) {
        throw new Error('When OC auto-login is enabled (shared credentials), ocLoginUser and ocLoginPassword are required');
      }
      credentials.oc = {
        ocAutoLogin: true,
        loginUser: u,
        loginPassword: p,
        loginServers: {},
        loginTokens: {},
      };
    }
  }

  const credentialsPath = path.isAbsolute(credFileName)
    ? credFileName
    : path.resolve(masterDir, credFileName);

  return { master, credentials, credentialsPath };
}

function writeSetupFiles(configAbsPath, master, credentials, credentialsPath, setupBody) {
  atomicWriteJson(configAbsPath, master);
  const needCred = (credentials.users && Object.keys(credentials.users).length > 0) || credentials.oc;
  if (needCred) {
    atomicWriteJson(credentialsPath, credentials);
  }
  const rt = master && master.runtimeRoot;
  const bs = master && master.kafka && master.kafka.bootstrapServers;
  if (rt && bs) {
    const body = setupBody && typeof setupBody === 'object' ? setupBody : {};
    if (hasFullKafkaConnection(body)) {
      materializeKafkaConnectionFiles(body, master);
    } else {
      ensureKafkaClientPropertyTemplates(rt, bs);
      ensureKafkaEnvPropertyTemplatesFromMaster(master);
    }
  }
}

/**
 * Map existing master.config.json → wizard POST body shape (passwords / OC secrets not included).
 * @param {object} master - parsed master config
 */
function masterToSetupWizardBody(master) {
  if (!master || typeof master !== 'object') return null;
  const kafka = master.kafka || {};
  const oc = master.oc || {};
  const portal = master.portal || {};
  const sites = Array.isArray(master.fallbackSites) ? master.fallbackSites : [];
  const defaultSecret = 'kafka-server-side-credentials';
  const k8sSn = String(kafka.k8sSecretName || defaultSecret).trim() || defaultSecret;
  const ocSites = sites.map((s) => ({
    ocContext: String(s.ocContext || '').trim(),
    namespace: String(s.namespace || '').trim(),
    apiServer: (oc.loginServers && s.ocContext && oc.loginServers[s.ocContext])
      ? String(oc.loginServers[s.ocContext]).trim()
      : '',
    loginUser: '',
    loginPassword: '',
  }));
  const envBlock = master.environments;
  const envEnabled = !!(envBlock && envBlock.enabled === true);
  const rawEnvItems = envEnabled && Array.isArray(envBlock.environments) ? envBlock.environments : [];
  const environmentBootstrapOverrides = {};
  const envItems = rawEnvItems.map((e) => {
    if (!e || typeof e !== 'object') return e;
    const copy = { ...e };
    if (Array.isArray(copy.sites)) {
      copy.sites = copy.sites.map((s) => {
        if (!s || typeof s !== 'object') return s;
        const api = String(s.apiServer || '').trim();
        const ctx = String(s.ocContext || '').trim();
        const fromLogin = oc.loginServers && ctx && oc.loginServers[ctx]
          ? String(oc.loginServers[ctx]).trim()
          : '';
        return {
          ...s,
          apiServer: api || fromLogin,
        };
      });
    }
    return copy;
  });
  for (const e of envItems) {
    if (e && e.id && typeof e.bootstrapServers === 'string' && e.bootstrapServers.trim()) {
      environmentBootstrapOverrides[e.id] = e.bootstrapServers.trim();
    }
  }

  let ocpClusterApiUrl = '';
  if (ocSites.length && ocSites[0].apiServer) {
    ocpClusterApiUrl = String(ocSites[0].apiServer).trim();
  } else if (oc.loginServers && typeof oc.loginServers === 'object') {
    const vals = Object.values(oc.loginServers).filter((v) => v && String(v).trim());
    if (vals.length) ocpClusterApiUrl = String(vals[0]).trim();
  }

  return {
    runtimeRoot: String(master.runtimeRoot || '').trim(),
    kafkaBootstrap: String(kafka.bootstrapServers || '').trim(),
    scriptName: String(kafka.scriptName || 'gen.sh').trim(),
    k8sSecretName: k8sSn,
    customK8sSecret: k8sSn !== defaultSecret,
    clientPropertiesFile: String(kafka.clientPropertiesFile || 'kafka-client.properties').trim(),
    adminPropertiesFile: String(kafka.adminPropertiesFile || 'kafka-client-master.properties').trim(),
    ocPath: String(oc.ocPath != null ? oc.ocPath : '/host/usr/bin').trim(),
    kubeconfig: String(oc.kubeconfig || '{runtimeRoot}/.kube/config').trim(),
    ocAutoLogin: oc.autoLogin === true,
    ocTopology: sites.length >= 2 ? 'dual' : 'single',
    ocSites: sites.length ? ocSites : undefined,
    portalPort: portal.port != null ? String(portal.port) : '3443',
    httpsEnabled: !!(portal.https && portal.https.enabled),
    httpsKeyPath: String((portal.https && portal.https.keyPath) || '/app/ssl/server.key').trim(),
    httpsCertPath: String((portal.https && portal.https.certPath) || '/app/ssl/server.crt').trim(),
    authEnabled: !!(portal.auth && portal.auth.enabled),
    credentialsFile: String((portal.auth && portal.auth.credentialsFile) || 'credentials.json').trim(),
    environmentsEnabled: envEnabled,
    defaultEnvironmentId: String((envBlock && envBlock.defaultEnvironmentId) || 'dev').trim(),
    environmentItems: envItems,
    environmentBootstrapOverrides:
      Object.keys(environmentBootstrapOverrides).length ? environmentBootstrapOverrides : undefined,
    ocpClusterApiUrl: ocpClusterApiUrl || undefined,
  };
}

module.exports = {
  atomicWriteJson,
  configDirectoryWritable,
  buildFilesFromSetupBody,
  writeSetupFiles,
  normalizeOcSitesFromBody,
  masterToSetupWizardBody,
  ensureKafkaClientPropertyTemplates,
  ensureKafkaEnvPropertyTemplatesFromMaster,
  DEFAULT_CLIENT_PROPS_FILE,
  DEFAULT_ADMIN_PROPS_FILE,
};
