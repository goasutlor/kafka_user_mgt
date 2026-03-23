'use strict';

const express = require('express');
const session = require('express-session');
const path = require('path');
const fs = require('fs');
const https = require('https');
const { spawn, spawnSync } = require('child_process');
const { verifyPassword, isHashedStored } = require('./lib/auth-hash');
const { decrypt: decryptOcCredential } = require('./lib/oc-encrypt');
const {
  isMasterConfig,
  expandMasterToLegacy,
  syncEnvironmentsDerivedFile,
  resolveRuntimeKubeconfigPath,
} = require('./lib/master-config');
const {
  configDirectoryWritable,
  buildFilesFromSetupBody,
  writeSetupFiles,
  masterToSetupWizardBody,
} = require('./lib/setup-writer');
const { runSetupPreview } = require('./lib/setup-validate');
const { validateKafkaConnectionCompleteness } = require('./lib/setup-kafka-files');
const {
  RESET_CONFIRM_PHRASE,
  collectWipePaths,
  verifyPortalCredentialsForWipe,
  performWipe,
} = require('./lib/setup-reset');

const CONFIG_PATH = process.env.CONFIG_PATH || path.join(__dirname, '..', 'config', 'web.config.json');
const AUTH_USERS_FILE = process.env.AUTH_USERS_FILE || path.join(path.dirname(CONFIG_PATH), 'auth-users.json');
const SESSION_SECRET = process.env.SESSION_SECRET || 'kafka-usermgmt-session-secret-change-in-production';
const STATIC_DIR = process.env.STATIC_DIR || path.join(__dirname, '..', '..', 'web-ui-mockup');

let SETUP_MODE = false;

function getConfigAbsPath() {
  return path.isAbsolute(CONFIG_PATH) ? CONFIG_PATH : path.resolve(process.cwd(), CONFIG_PATH);
}

/** Scheme + host as seen by the browser (honours reverse-proxy headers when trust proxy is enabled). */
function clientFacingBaseUrl(req) {
  let proto = String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim().toLowerCase();
  if (!proto && req.secure) proto = 'https';
  if (!proto) proto = 'http';
  const host = String(req.headers['x-forwarded-host'] || req.headers.host || '').split(',')[0].trim();
  const safeHost = host || 'localhost';
  return `${proto}://${safeHost}`;
}

// Version: from env (Docker build) or package.json
let APP_VERSION = process.env.APP_VERSION || '';
if (!APP_VERSION) {
  try { APP_VERSION = require('./package.json').version; } catch (_) {}
}
APP_VERSION = APP_VERSION || '0.0.0';

/** Remove ANSI escapes from gen.sh / oc output for API + UI readability */
function stripAnsi(str) {
  if (typeof str !== 'string') return str;
  return str
    .replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '')
    .replace(/\x1b\[?[0-9;]*[a-zA-Z]?/g, '')
    .replace(/\r/g, '')
    .trim();
}

const app = express();

const IS_PRODUCTION = process.env.NODE_ENV === 'production';
const USE_HTTPS_DIRECT = process.env.USE_HTTPS === '1';
const TRUST_PROXY = process.env.TRUST_PROXY === '1';

// Behind Nginx / LB that terminates TLS: set TRUST_PROXY=1 and X-Forwarded-Proto (session cookies use secure: auto).
if (TRUST_PROXY) {
  app.set('trust proxy', 1);
}

/** Cookie options for logout / clearCookie — must match how the session cookie was issued. */
function sessionCookieResponseOpts(req) {
  const base = { path: '/', httpOnly: true, sameSite: 'lax' };
  if (!IS_PRODUCTION) return base;
  if (USE_HTTPS_DIRECT) return { ...base, secure: true };
  if (TRUST_PROXY) {
    const proto = String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim().toLowerCase();
    if (proto === 'https') return { ...base, secure: true };
  }
  return base;
}

let sessionCookieSecure = false;
let sessionProxy = false;
if (IS_PRODUCTION) {
  if (USE_HTTPS_DIRECT) {
    sessionCookieSecure = true;
  } else if (TRUST_PROXY) {
    sessionCookieSecure = 'auto';
    sessionProxy = true;
  }
}

// Security headers (no Helmet dependency; set essential ones only)
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  const hsts = process.env.HSTS_MAX_AGE;
  if (hsts && /^\d+$/.test(String(hsts).trim())) {
    let clientHttps = !!req.secure;
    if (!clientHttps && TRUST_PROXY) {
      const proto = String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim().toLowerCase();
      clientHttps = proto === 'https';
    }
    if (clientHttps) {
      const inc = process.env.HSTS_INCLUDE_SUBDOMAINS === '1' ? '; includeSubDomains' : '';
      res.setHeader('Strict-Transport-Security', `max-age=${String(hsts).trim()}${inc}`);
    }
  }
  next();
});

const jsonBodyLimitDefault = express.json({ limit: '256kb' });
const jsonBodyLimitSetup = express.json({ limit: '12mb' });
app.use((req, res, next) => {
  const p = req.path || '';
  if (
    (req.method === 'POST' || req.method === 'PUT' || req.method === 'PATCH')
    && (p === '/api/setup/preview' || p === '/api/setup/apply')
  ) {
    return jsonBodyLimitSetup(req, res, next);
  }
  return jsonBodyLimitDefault(req, res, next);
});

// Session (for login when server.auth.enabled). Set SESSION_SECRET in production.
app.use(session({
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  name: 'kafka_usermgmt_sid',
  proxy: sessionProxy,
  cookie: {
    httpOnly: true,
    secure: sessionCookieSecure,
    maxAge: 24 * 60 * 60 * 1000,
    sameSite: 'lax',
  },
}));

// Shell for spawn (avoid ENOENT: try host-mounted bash, then container bash, then sh)
const SHELL_CMD = (function () {
  try {
    if (fs.existsSync('/host/usr/bin/bash')) return '/host/usr/bin/bash'; // when host /usr/bin is mounted at /host/usr/bin
    if (fs.existsSync('/usr/bin/bash')) return '/usr/bin/bash';
    if (fs.existsSync('/bin/bash')) return '/bin/bash';
    if (fs.existsSync('/bin/sh')) return '/bin/sh';
  } catch (_) {}
  return 'sh';
})();

let config;

function getConfigDir() {
  return path.dirname(getConfigAbsPath());
}

/** Merge portal + OC credentials from a single JSON file (server.auth.secretsFile). */
function mergeAuthSecretsFromFile(cfg) {
  const auth = cfg.server?.auth || {};
  const rel = auth.secretsFile;
  if (!rel || typeof rel !== 'string') return;
  const configDir = getConfigDir();
  const secretsPath = path.isAbsolute(rel) ? rel : path.resolve(configDir, rel);
  if (!fs.existsSync(secretsPath)) return;
  try {
    const data = JSON.parse(fs.readFileSync(secretsPath, 'utf8'));
    if (!cfg.gen) cfg.gen = {};
    const oc = data.oc || data.openshift;
    if (oc && typeof oc === 'object') {
      if (oc.loginUser) cfg.gen.ocLoginUser = oc.loginUser;
      if (oc.loginPassword) cfg.gen.ocLoginPassword = oc.loginPassword;
      if (oc.loginServers && typeof oc.loginServers === 'object') {
        cfg.gen.ocLoginServers = { ...(cfg.gen.ocLoginServers || {}), ...oc.loginServers };
      }
      if (oc.loginTokens && typeof oc.loginTokens === 'object') {
        cfg.gen.ocLoginTokens = { ...(cfg.gen.ocLoginTokens || {}), ...oc.loginTokens };
      }
      if (oc.ocAutoLogin === true || oc.autoLogin === true) cfg.gen.ocAutoLogin = true;
      if (oc.loginCredentials && typeof oc.loginCredentials === 'object') {
        cfg.gen.ocLoginCredentials = { ...(cfg.gen.ocLoginCredentials || {}), ...oc.loginCredentials };
      }
    }
  } catch (e) {
    console.warn('[config] auth secrets file:', e.message);
  }
}

// When gen.rootDir is set, derive scriptPath, baseDir, downloadDir, kafkaBin, clientConfig, adminConfig, logFile so one root = ready to move.
function resolveGenPaths(cfg) {
  const g = cfg.gen || {};
  const root = g.rootDir ? path.resolve(g.rootDir) : null;
  if (!root) return;
  const defaults = {
    baseDir: root,
    scriptPath: path.join(root, g.scriptName || 'confluent-usermanagement.sh'),
    downloadDir: path.join(root, 'user_output'),
    kafkaBin: path.join(root, 'kafka_2.13-3.6.1', 'bin'),
    clientConfig: path.join(root, 'configs', 'kafka-client.properties'),
    adminConfig: path.join(root, 'configs', 'kafka-client-master.properties'),
    logFile: path.join(root, 'provisioning.log'),
  };
  if (!cfg.gen) cfg.gen = {};
  Object.keys(defaults).forEach(function (k) {
    if (cfg.gen[k] == null || cfg.gen[k] === '') cfg.gen[k] = defaults[k];
  });
  // kubeconfigPath: normalized after load (see normalizeGenKubeconfigPath) to pick config vs config-both when one is missing.
}

/** Host oc is mounted at /host/usr/bin in Docker/Podman (see docker-compose / container-run-config). */
function defaultOcPathForContainer() {
  try {
    if (fs.existsSync('/host/usr/bin/oc')) return '/host/usr/bin';
  } catch (_) { /* ignore */ }
  return '/usr/bin';
}

function normalizeGenKubeconfigPath(cfg) {
  try {
    const g = cfg.gen || {};
    if (!g.kubeconfigPath || typeof g.kubeconfigPath !== 'string' || !String(g.kubeconfigPath).trim()) return;
    const rt = path.resolve(g.baseDir || '/opt/kafka-usermgmt');
    const cfgDir = path.dirname(getConfigAbsPath());
    const pth = path.isAbsolute(g.kubeconfigPath)
      ? g.kubeconfigPath
      : path.resolve(cfgDir, g.kubeconfigPath);
    cfg.gen.kubeconfigPath = resolveRuntimeKubeconfigPath(pth, rt);
  } catch (_) { /* ignore */ }
}

/** Container image ships gen.sh at /app/bundled-gen (not on host runtime mount). Override with GEN_USE_HOST_SCRIPT=1 to use config path if present. */
const GEN_BUNDLED_SCRIPT_PATH = process.env.GEN_BUNDLED_SCRIPT_PATH || '/app/bundled-gen/gen.sh';

function ensureGenScriptPath(cfg) {
  try {
    if (!cfg || !cfg.gen) return;
    const bundled = GEN_BUNDLED_SCRIPT_PATH;
    const hasBundled = bundled && fs.existsSync(bundled);
    const sp = cfg.gen.scriptPath;
    const hostOk = sp && fs.existsSync(sp);
    const preferHost = process.env.GEN_USE_HOST_SCRIPT === '1';
    if (hasBundled && !preferHost) {
      if (!hostOk || sp !== bundled) {
        cfg.gen.scriptPath = bundled;
        if (!hostOk) {
          console.warn('[config] gen.scriptPath not found at', sp, '— using image bundled', bundled);
        }
      }
      return;
    }
    if (hostOk) return;
    if (hasBundled) cfg.gen.scriptPath = bundled;
  } catch (_) { /* ignore */ }
}

function loadConfig() {
  const p = getConfigAbsPath();
  if (!fs.existsSync(p)) {
    throw new Error(`Config not found: ${p} — open /setup.html for first-time setup (mount a writable directory at the config path).`);
  }
  const raw = JSON.parse(fs.readFileSync(p, 'utf8'));
  if (isMasterConfig(raw)) {
    config = expandMasterToLegacy(raw, p);
  } else {
    config = raw;
  }
  resolveGenPaths(config);
  normalizeGenKubeconfigPath(config);
  mergeAuthSecretsFromFile(config);
  syncEnvironmentsDerivedFile(config);
  ensureGenScriptPath(config);
  return config;
}

// Auth users: optional single file (server.auth.secretsFile) with { users }, else auth-users.json.
function getAuthSecretsFilePath() {
  if (!config) try { loadConfig(); } catch (_) { return null; }
  const rel = config.server?.auth?.secretsFile;
  if (!rel || typeof rel !== 'string') return null;
  const configDir = getConfigDir();
  return path.isAbsolute(rel) ? rel : path.resolve(configDir, rel);
}

function getAuthUsersFilePath() {
  if (!config) try { loadConfig(); } catch (_) { return null; }
  const secrets = getAuthSecretsFilePath();
  if (secrets && fs.existsSync(secrets)) return secrets;
  const configDir = getConfigDir();
  const f = config.server?.auth?.usersFile;
  if (f) return path.isAbsolute(f) ? f : path.resolve(configDir, f);
  return path.join(configDir, 'auth-users.json');
}

function loadAuthUsersFromFile() {
  const secretsPath = getAuthSecretsFilePath();
  if (secretsPath && fs.existsSync(secretsPath)) {
    try {
      const raw = fs.readFileSync(secretsPath, 'utf8');
      const data = JSON.parse(raw);
      if (data && data.users && typeof data.users === 'object') return data.users;
    } catch (_) {
      return {};
    }
    return {};
  }
  const filePath = getAuthUsersFilePath();
  if (!filePath || !fs.existsSync(filePath)) return {};
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    const data = JSON.parse(raw);
    return (data && data.users && typeof data.users === 'object') ? data.users : {};
  } catch (_) {
    return {};
  }
}

function getAuthConfig() {
  if (!config) try { loadConfig(); } catch (_) { return { enabled: false }; }
  const auth = config.server?.auth || {};
  const enabled = auth.enabled === true || process.env.AUTH_ENABLED === '1';
  if (!enabled) return { enabled: false };
  const users = loadAuthUsersFromFile();
  return { enabled: true, users: Object.keys(users).length ? users : null };
}

function checkCredentials(username, password) {
  const auth = getAuthConfig();
  if (!auth.enabled) return true;
  if (!auth.users || typeof auth.users !== 'object') return false;
  const u = (username || '').trim();
  if (!u || typeof password !== 'string') return false;
  const stored = auth.users[u];
  if (isHashedStored(stored)) return verifyPassword(password, stored);
  return stored === password;
}

function getAuthenticatedUser(req) {
  return req.session && req.session.user;
}

function getDataDir() {
  const authPath = getAuthUsersFilePath();
  if (!authPath) return null;
  const dir = path.dirname(authPath);
  try {
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    return dir;
  } catch (_) {
    return null;
  }
}

function appendAuditLog(req, action, detail) {
  const dataDir = getDataDir();
  if (!dataDir) return;
  try {
    const line = JSON.stringify({
      time: new Date().toISOString(),
      action,
      user: getAuthenticatedUser(req) || null,
      detail: detail || null,
    }) + '\n';
    fs.appendFileSync(path.join(dataDir, 'audit.log'), line, 'utf8');
  } catch (_) {}
}

function appendDownloadHistory(req, filename, packName) {
  const dataDir = getDataDir();
  if (!dataDir) return;
  const filePath = path.join(dataDir, 'download-history.json');
  try {
    let list = [];
    if (fs.existsSync(filePath)) {
      try {
        list = JSON.parse(fs.readFileSync(filePath, 'utf8'));
      } catch (_) {}
    }
    if (!Array.isArray(list)) list = [];
    list.push({
      date: new Date().toISOString().slice(0, 10),
      datetime: new Date().toISOString(),
      filename: filename || '',
      packName: packName || '',
      user: getAuthenticatedUser(req) || null,
    });
    fs.writeFileSync(filePath, JSON.stringify(list, null, 2), 'utf8');
  } catch (_) {}
}

// First-time setup: block operational APIs until master.config.json exists (CI/CD-safe image).
app.use((req, res, next) => {
  if (!SETUP_MODE) return next();
  const url = (req.path || req.url || '').split('?')[0];
  if (url.startsWith('/api/setup')) return next();
  if (url.startsWith('/api/preflight')) return next();
  if (url === '/api/version') return next();
  if (url.startsWith('/api/')) {
    const base = clientFacingBaseUrl(req);
    return res.status(503).json({
      ok: false,
      setupRequired: true,
      error: 'First-time setup required — open the setup page and save configuration to the mounted config volume.',
      setupPageUrl: `${base}/setup.html`,
      appUrl: `${base}/`,
    });
  }
  next();
});

// Auth/session API and HTML must not be cached (avoids stale /api/me after docs → app; helps post-logout back button).
app.use((req, res, next) => {
  const p = req.path || '';
  if (
    p === '/api/me'
    || p === '/api/auth-mode'
    || p === '/api/login'
    || p === '/api/logout'
    || p === '/api/session/environment'
    || p === '/api/setup/reset'
  ) {
    res.set('Cache-Control', 'no-store, private, no-cache');
    res.set('Pragma', 'no-cache');
    res.set('Vary', 'Cookie');
  }
  next();
});

app.post('/api/setup/preview', async (req, res) => {
  const expected = process.env.SETUP_TOKEN;
  if (expected && String(req.headers['x-setup-token'] || '') !== expected) {
    return res.status(403).json({ ok: false, error: 'Invalid or missing X-Setup-Token header' });
  }
  try {
    const configAbs = getConfigAbsPath();
    const rawBody = req.body && typeof req.body === 'object' ? { ...req.body } : {};
    const deepVerify = !!rawBody.deepVerify;
    const quickVerify = !!rawBody.quickVerify;
    delete rawBody.deepVerify;
    delete rawBody.quickVerify;
    const out = await runSetupPreview(rawBody, configAbs, { deepVerify, quickVerify });
    res.json({ ok: true, ...out, deepVerifyRan: deepVerify, quickVerifyRan: quickVerify });
  } catch (e) {
    res.status(400).json({ ok: false, error: e.message || String(e) });
  }
});

app.get('/api/setup/status', (req, res) => {
  const configAbs = getConfigAbsPath();
  const present = fs.existsSync(configAbs);
  const dirOk = configDirectoryWritable(configAbs);
  const base = clientFacingBaseUrl(req);
  const resetPageUrl = `${base}/reset-config.html`;
  const resetConfig = { available: false, resetPageUrl, confirmPhrase: RESET_CONFIRM_PHRASE, reason: null };
  if (present) {
    try {
      const raw = JSON.parse(fs.readFileSync(configAbs, 'utf8'));
      if (!isMasterConfig(raw)) {
        resetConfig.reason = 'Not master.config.json — remove files on the host or migrate to master format for password-gated reset.';
      } else if (!(raw.portal && raw.portal.auth && raw.portal.auth.enabled === true)) {
        resetConfig.reason = 'Portal authentication is not enabled in master.config — enable it first, or delete deploy/config on the host.';
      } else {
        resetConfig.available = true;
      }
    } catch (_) {
      resetConfig.reason = 'Could not read configuration file.';
    }
  } else {
    resetConfig.reason = 'No configuration file yet.';
  }
  res.json({
    ok: true,
    setupRequired: SETUP_MODE || !present,
    setupPageUrl: `${base}/setup.html`,
    appUrl: `${base}/`,
    reconfigureAllowed: process.env.ALLOW_SETUP_RECONFIGURE === '1',
    configPath: configAbs,
    configDirWritable: dirOk.ok,
    configDirError: dirOk.ok ? null : dirOk.error,
    setupTokenRequired: !!process.env.SETUP_TOKEN,
    resetConfig,
  });
});

app.get('/api/setup/prefill', (req, res) => {
  const expected = process.env.SETUP_TOKEN;
  if (expected && String(req.headers['x-setup-token'] || '') !== expected) {
    return res.status(403).json({ ok: false, error: 'Invalid or missing X-Setup-Token header' });
  }
  const configAbs = getConfigAbsPath();
  if (!fs.existsSync(configAbs)) {
    return res.status(404).json({ ok: false, error: 'No configuration file at CONFIG_PATH yet' });
  }
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(configAbs, 'utf8'));
  } catch (e) {
    return res.status(500).json({ ok: false, error: 'Could not read configuration file', detail: e.message });
  }
  if (!isMasterConfig(raw)) {
    return res.status(400).json({
      ok: false,
      error: 'Prefill only supports master.config.json. Legacy web.config.json must be edited or migrated manually.',
    });
  }
  res.json({ ok: true, wizard: masterToSetupWizardBody(raw) });
});

// Same checks as scripts/verify-golive.sh (Linux/container). Set GOLIVE_REPORT_TOKEN; send X-Golive-Token. Optional query portalBaseUrl.
app.get('/api/preflight/golive', (req, res) => {
  const expected = process.env.GOLIVE_REPORT_TOKEN;
  if (!expected) {
    return res.status(503).json({
      ok: false,
      error: 'GOLIVE_REPORT_TOKEN is not set — run scripts/verify-golive.sh on the helper node, or set the token to enable this API.',
    });
  }
  if (String(req.headers['x-golive-token'] || '') !== String(expected)) {
    return res.status(403).json({ ok: false, error: 'Invalid or missing X-Golive-Token header' });
  }
  if (process.platform === 'win32') {
    return res.status(501).json({
      ok: false,
      error: 'Go-live verification runs on Linux (container or helper). Use WSL or execute scripts/verify-golive.sh on the deployment host.',
    });
  }
  const bundledVg = '/app/bundled-gen/verify-golive.sh';
  const scriptPath = process.env.GOLIVE_SCRIPT_PATH
    || (fs.existsSync(bundledVg) ? bundledVg
      : (fs.existsSync('/opt/kafka-usermgmt/verify-golive.sh')
        ? '/opt/kafka-usermgmt/verify-golive.sh'
        : path.join(__dirname, '..', '..', 'scripts', 'verify-golive.sh')));
  if (!fs.existsSync(scriptPath)) {
    return res.status(500).json({ ok: false, error: `verify-golive.sh not found at ${scriptPath}` });
  }
  const bashArgs = [scriptPath, '--json'];
  try {
    const configAbs = getConfigAbsPath();
    if (fs.existsSync(configAbs)) {
      const raw = JSON.parse(fs.readFileSync(configAbs, 'utf8'));
      if (isMasterConfig(raw)) {
        bashArgs.push('--config', configAbs);
      }
    }
  } catch (_) { /* ignore */ }
  const portal = String(req.query.portalBaseUrl || process.env.GOLIVE_PORTAL_BASE_URL || '').trim();
  if (portal) {
    bashArgs.push('--portal-url', portal);
  }
  const r = spawnSync('bash', bashArgs, {
    encoding: 'utf8',
    maxBuffer: 20 * 1024 * 1024,
    timeout: 180000,
    env: { ...process.env },
  });
  const lines = (r.stdout || '').split('\n').filter(Boolean);
  const checks = [];
  let summary = null;
  for (let i = 0; i < lines.length; i++) {
    try {
      const o = JSON.parse(lines[i]);
      if (o.type === 'summary') summary = o;
      else checks.push(o);
    } catch (_) { /* skip non-JSON */ }
  }
  const ok = !!(summary && summary.ok === true);
  return res.status(200).json({
    ok,
    scriptExitCode: r.status,
    signal: r.signal,
    checks,
    summary,
    stderrTail: (r.stderr || '').slice(-4000),
  });
});

app.post('/api/setup/apply', (req, res) => {
  const expected = process.env.SETUP_TOKEN;
  if (expected && String(req.headers['x-setup-token'] || '') !== expected) {
    return res.status(403).json({ ok: false, error: 'Invalid or missing X-Setup-Token header' });
  }
  const configAbs = getConfigAbsPath();
  if (fs.existsSync(configAbs) && process.env.ALLOW_SETUP_RECONFIGURE !== '1') {
    return res.status(403).json({
      ok: false,
      error: 'Configuration already exists. Set ALLOW_SETUP_RECONFIGURE=1 on the container to overwrite (use with care).',
    });
  }
  const dirOk = configDirectoryWritable(configAbs);
  if (!dirOk.ok) {
    return res.status(500).json({ ok: false, error: 'Config directory not writable', detail: dirOk.error });
  }
  try {
    const body = req.body || {};
    const built = buildFilesFromSetupBody(body, configAbs);
    validateKafkaConnectionCompleteness(body);
    if (!isMasterConfig(built.master)) {
      return res.status(500).json({ ok: false, error: 'Internal error: invalid master configuration shape' });
    }
    writeSetupFiles(configAbs, built.master, built.credentials, built.credentialsPath, body);
    SETUP_MODE = false;
    config = null;
    loadConfig();
    setImmediate(() => {
      runOcLoginIfConfigured()
        .then(() => ensureOcSessions())
        .catch((err) => console.error('[oc-auto-login]', err.message));
      startOcSessionRefreshInterval();
    });
  } catch (e) {
    return res.status(400).json({ ok: false, error: e.message || String(e) });
  }
  res.json({
    ok: true,
    message: 'Configuration saved. You can sign in now. If you changed the port in the form, restart the container so the listener matches.',
  });
});

/**
 * Wipe saved portal configuration (master + credentials + audit/history + derived environments.json).
 * Requires Portal auth enabled + master.config; re-authenticates with username/password + confirm phrase.
 * Upgrading the container image does not call this — bind-mounted config persists until you reset or delete files.
 */
app.post('/api/setup/reset', (req, res) => {
  const tokenExpected = process.env.SETUP_TOKEN;
  if (tokenExpected && String(req.headers['x-setup-token'] || '') !== tokenExpected) {
    return res.status(403).json({ ok: false, error: 'Invalid or missing X-Setup-Token header' });
  }
  const configAbs = getConfigAbsPath();
  if (!fs.existsSync(configAbs)) {
    return res.status(400).json({ ok: false, error: 'No configuration file to reset' });
  }
  const body = req.body && typeof req.body === 'object' ? req.body : {};
  const phrase = String(body.confirmPhrase || '').trim();
  if (phrase !== RESET_CONFIRM_PHRASE) {
    return res.status(400).json({
      ok: false,
      error: `Confirmation phrase must be exactly: ${RESET_CONFIRM_PHRASE}`,
      confirmPhrase: RESET_CONFIRM_PHRASE,
    });
  }
  try {
    verifyPortalCredentialsForWipe(configAbs, body.username, body.password);
  } catch (e) {
    const msg = e.message || String(e);
    const code = /Invalid username or password/.test(msg) ? 401 : 400;
    return res.status(code).json({ ok: false, error: msg });
  }
  const dirOk = configDirectoryWritable(configAbs);
  if (!dirOk.ok) {
    return res.status(500).json({ ok: false, error: 'Config directory not writable', detail: dirOk.error });
  }
  let wipe;
  try {
    wipe = collectWipePaths(configAbs);
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message || String(e) });
  }
  const result = performWipe(wipe.paths);
  clearOcSessionRefreshInterval();
  config = null;
  SETUP_MODE = true;
  const payload = {
    ok: true,
    message: 'Configuration removed. Open /setup.html to run first-time setup again.',
    setupPageUrl: `${clientFacingBaseUrl(req)}/setup.html`,
    removed: result.removed,
    errors: result.errors.length ? result.errors : undefined,
    warningCredentialOutsideConfigDir: wipe.skippedCredentialOutsideConfigDir
      ? 'credentials.json path is outside the config directory — that file was not deleted; remove it on the host if needed.'
      : undefined,
  };
  if (req.session) {
    return req.session.destroy(() => res.json(payload));
  }
  return res.json(payload);
});

// Protect /api/* except login, me, version
app.use('/api', (req, res, next) => {
  const auth = getAuthConfig();
  if (!auth.enabled) return next();
  const p = req.path || '';
  if (p.startsWith('/setup/')) return next();
  if (p === '/login' && req.method === 'POST') return next();
  if (p === '/me' && req.method === 'GET') return next();
  if (p === '/version' && req.method === 'GET') return next();
  if (p === '/auth-mode' && req.method === 'GET') return next();
  if (p === '/login-challenge' && req.method === 'GET') return next();
  if (p === '/environments' && req.method === 'GET') return next();
  if (getAuthenticatedUser(req)) return next();
  return res.status(401).json({ ok: false, error: 'Unauthorized', authRequired: true });
});

function randomSecurityCode(len) {
  let s = '';
  for (let i = 0; i < (len || 6); i++) s += Math.floor(Math.random() * 10);
  return s;
}

app.get('/api/login-challenge', (req, res) => {
  const auth = getAuthConfig();
  if (!auth.enabled) return res.json({ code: '' });
  const code = randomSecurityCode(6);
  req.session.loginChallenge = code;
  req.session.save((err) => {
    if (err) return res.status(500).json({ ok: false, error: 'Session error' });
    res.json({ code });
  });
});

app.get('/api/environments', (req, res) => {
  try {
    if (!config) loadConfig();
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message });
  }
  const st = getEnvironmentsState();
  if (st.active && st.list.length) {
    const environments = (st.list || []).map((e) => ({
      id: e.id,
      label: e.label || e.id,
      shortLabel: e.shortLabel || e.label || e.id,
      badgeColor: e.badgeColor || null,
    }));
    return res.json({
      ok: true,
      enabled: true,
      selectionRequired: st.list.length > 1,
      singleDeployment: false,
      environments,
      defaultEnvironmentId: st.defaultId,
    });
  }
  try {
    const sites = getSitesFromConfig();
    if (sites && sites.length) {
      if (sites.length > 1) {
        const environments = sites.map((s, i) => {
          const ns = String(s.namespace || '').trim();
          const ctx = String(s.ocContext || '').trim();
          const shortLabel = (ns ? ns.slice(0, 10) : `S${i}`).toUpperCase();
          return {
            id: `lns-${i}`,
            label: ns ? `${ns} (${ctx || 'context'})` : (ctx || `Site ${i}`),
            shortLabel,
            badgeColor: '#6e7781',
          };
        });
        return res.json({
          ok: true,
          enabled: true,
          selectionRequired: true,
          singleDeployment: false,
          legacyNamespacePick: true,
          environments,
          defaultEnvironmentId: 'lns-0',
        });
      }
      const ns = sites.map((s) => s.namespace).filter(Boolean);
      const primaryNs = ns[0] || '';
      const shortLabel = (primaryNs ? primaryNs.slice(0, 10) : 'NS').toUpperCase();
      return res.json({
        ok: true,
        enabled: true,
        selectionRequired: false,
        singleDeployment: true,
        environments: [{
          id: 'lns-0',
          label: primaryNs ? `Namespace: ${primaryNs}` : 'Deployment target',
          shortLabel,
          badgeColor: '#6e7781',
        }],
        defaultEnvironmentId: 'lns-0',
      });
    }
  } catch (_) { /* ignore */ }
  if (config && config.gen) {
    return res.json({
      ok: true,
      enabled: true,
      selectionRequired: false,
      singleDeployment: true,
      unconfigured: true,
      environments: [{
        id: 'default',
        label: 'Cluster targets not set — complete Setup',
        shortLabel: 'SETUP',
        badgeColor: '#64748b',
      }],
      defaultEnvironmentId: 'default',
    });
  }
  res.json({
    ok: true,
    enabled: false,
    selectionRequired: false,
    singleDeployment: false,
    environments: [],
    defaultEnvironmentId: null,
  });
});

app.post('/api/login', (req, res) => {
  const auth = getAuthConfig();
  const st = getEnvironmentsState();
  function applySessionEnvironment() {
    if (!req.session) return true;
    const sitesAll = (() => {
      try { return getSitesFromConfig(); } catch (_) { return []; }
    })();
    if (st.active) {
      delete req.session.legacySiteIndex;
      const raw = (req.body || {}).environmentId;
      const eid = String(raw != null && raw !== '' ? raw : st.defaultId || '').trim();
      if (!eid) {
        res.status(400).json({ ok: false, error: 'Select an environment (Dev / SIT / UAT).' });
        return false;
      }
      if (!ENVIRONMENT_ID_REGEX.test(eid) || !st.list.some((e) => e.id === eid)) {
        res.status(400).json({ ok: false, error: 'Invalid environment' });
        return false;
      }
      req.session.activeEnvironmentId = eid;
      return true;
    }
    delete req.session.activeEnvironmentId;
    if (sitesAll && sitesAll.length > 1) {
      const raw = (req.body || {}).environmentId;
      const eid = String(raw != null && raw !== '' ? raw : '').trim();
      const m = eid.match(LEGACY_SITE_ID_REGEX);
      if (!m) {
        res.status(400).json({ ok: false, error: 'Select a namespace (target) before signing in.' });
        return false;
      }
      const idx = parseInt(m[1], 10);
      if (idx < 0 || idx >= sitesAll.length) {
        res.status(400).json({ ok: false, error: 'Invalid namespace target' });
        return false;
      }
      req.session.legacySiteIndex = idx;
      return true;
    }
    if (sitesAll && sitesAll.length === 1) {
      req.session.legacySiteIndex = 0;
      return true;
    }
    delete req.session.legacySiteIndex;
    return true;
  }
  if (!auth.enabled) {
    if (!applySessionEnvironment()) return;
    return req.session.save((err) => {
      if (err) return res.status(500).json({ ok: false, error: 'Session error' });
      res.json({ ok: true, user: 'guest' });
    });
  }
  const { username, password, securityCode } = req.body || {};
  const expected = req.session && req.session.loginChallenge;
  if (expected && String(securityCode || '').trim() !== expected) {
    return res.status(401).json({ ok: false, error: 'Invalid security code' });
  }
  const user = (username || '').trim();
  if (!checkCredentials(user || undefined, password)) {
    return res.status(401).json({ ok: false, error: 'Invalid username or password' });
  }
  if (!applySessionEnvironment()) return;
  if (req.session) req.session.loginChallenge = undefined;
  req.session.user = user;
  req.session.save((err) => {
    if (err) return res.status(500).json({ ok: false, error: 'Session error' });
    res.json({ ok: true, user: req.session.user });
  });
});

app.get('/api/me', (req, res) => {
  const auth = getAuthConfig();
  const st = getEnvironmentsState();
  function attachEnvironment(payload) {
    if (!req.session) return payload;
    if (st.active) {
      const id = req.session.activeEnvironmentId || st.defaultId;
      const entry = st.list.find((e) => e.id === id) || st.list[0];
      if (!entry) return payload;
      const sites = sitesFromEnvironmentEntry(entry);
      payload.environment = {
        id: entry.id,
        label: entry.label,
        shortLabel: entry.shortLabel || entry.label,
        badgeColor: entry.badgeColor || null,
        namespaces: (sites || []).map((s) => s.namespace),
        multiEnv: true,
      };
      return payload;
    }
    try {
      const sitesAll = getSitesFromConfig();
      const sites = getSitesForRequest(req);
      if (sites && sites.length && sitesAll && sitesAll.length) {
        const ns = sites.map((s) => s.namespace).filter(Boolean);
        const ctxs = [...new Set(sites.map((s) => s.ocContext).filter(Boolean))];
        const primaryNs = ns[0] || '';
        const multiNs = sitesAll.length > 1;
        const idx = (req.session && typeof req.session.legacySiteIndex === 'number')
          ? req.session.legacySiteIndex
          : 0;
        payload.environment = {
          id: multiNs ? `lns-${idx}` : 'lns-0',
          label: primaryNs ? `Namespace: ${primaryNs}` : 'Deployment target',
          shortLabel: (primaryNs ? primaryNs.slice(0, 10) : 'NS').toUpperCase(),
          badgeColor: '#6e7781',
          namespaces: ns,
          ocContexts: ctxs,
          contextSummary: ctxs.join(', '),
          singleDeployment: !multiNs,
          multiEnv: multiNs,
          legacyNamespacePick: multiNs,
        };
      }
    } catch (_) { /* ignore */ }
    return payload;
  }
  if (!auth.enabled) return res.json(attachEnvironment({ ok: true, authRequired: false }));
  const user = getAuthenticatedUser(req);
  if (!user) return res.json({ ok: true, authRequired: true });
  res.json(attachEnvironment({ ok: true, user, authRequired: true, authMode: 'username_password' }));
});

app.post('/api/session/environment', (req, res) => {
  try {
    if (!config) loadConfig();
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message });
  }
  const auth = getAuthConfig();
  if (auth.enabled && !getAuthenticatedUser(req)) {
    return res.status(401).json({ ok: false, error: 'Unauthorized' });
  }
  const st = getEnvironmentsState();
  const eid = String((req.body || {}).environmentId || '').trim();
  if (st.active) {
    if (!ENVIRONMENT_ID_REGEX.test(eid) || !st.list.some((e) => e.id === eid)) {
      return res.status(400).json({ ok: false, error: 'Invalid environment' });
    }
    delete req.session.legacySiteIndex;
    req.session.activeEnvironmentId = eid;
    return req.session.save((err) => {
      if (err) return res.status(500).json({ ok: false, error: 'Session error' });
      const entry = st.list.find((e) => e.id === eid);
      const sites = sitesFromEnvironmentEntry(entry);
      res.json({
        ok: true,
        environment: {
          id: entry.id,
          label: entry.label,
          shortLabel: entry.shortLabel || entry.label,
          badgeColor: entry.badgeColor || null,
          namespaces: (sites || []).map((s) => s.namespace),
        },
      });
    });
  }
  const sitesAll = (() => {
    try { return getSitesFromConfig(); } catch (_) { return []; }
  })();
  if (!sitesAll || sitesAll.length < 2) {
    return res.status(400).json({ ok: false, error: 'Namespace switcher is not available (single target only).' });
  }
  const m = eid.match(LEGACY_SITE_ID_REGEX);
  if (!m) {
    return res.status(400).json({ ok: false, error: 'Invalid namespace target' });
  }
  const idx = parseInt(m[1], 10);
  if (idx < 0 || idx >= sitesAll.length) {
    return res.status(400).json({ ok: false, error: 'Invalid namespace target' });
  }
  delete req.session.activeEnvironmentId;
  req.session.legacySiteIndex = idx;
  const one = sitesAll[idx];
  const ns = String(one.namespace || '').trim();
  const ctx = String(one.ocContext || '').trim();
  req.session.save((err) => {
    if (err) return res.status(500).json({ ok: false, error: 'Session error' });
    res.json({
      ok: true,
      environment: {
        id: `lns-${idx}`,
        label: ns ? `Namespace: ${ns}` : 'Deployment target',
        shortLabel: (ns ? ns.slice(0, 10) : 'NS').toUpperCase(),
        badgeColor: '#6e7781',
        namespaces: ns ? [ns] : [],
        ocContexts: ctx ? [ctx] : [],
        contextSummary: ctx,
      },
    });
  });
});

app.get('/api/auth-mode', (req, res) => {
  const auth = getAuthConfig();
  if (!auth.enabled) return res.json({ authRequired: false });
  res.json({ authRequired: true, authMode: 'username_password' });
});

app.post('/api/logout', (req, res) => {
  const cookieOpts = sessionCookieResponseOpts(req);
  req.session.destroy((err) => {
    if (err) return res.status(500).json({ ok: false, error: 'Logout error' });
    res.clearCookie('kafka_usermgmt_sid', cookieOpts);
    res.json({ ok: true });
  });
});

function getBaseEnv(req) {
  if (!config) loadConfig();
  const g = config.gen || {};
  const baseDir = g.baseDir || process.env.BASE_HOST || '/opt/kafka-usermgmt';
  const ocPath = (g.ocPath && String(g.ocPath).trim()) || defaultOcPathForContainer();
  const kPaths = resolveKafkaCommandConfigPaths(req);
  const env = {
    ...process.env,
    // Put container PATH first so grep/dirname use container; append ocPath so oc from host is still found (avoids libpcre)
    PATH: (process.env.PATH || '/usr/bin:/bin') + (ocPath ? `:${ocPath}` : ''),
    GEN_BASE_DIR: baseDir,
    GEN_KAFKA_BIN: g.kafkaBin || path.join(baseDir, 'kafka_2.13-3.6.1/bin'),
    GEN_CLIENT_CONFIG: kPaths.clientConfig,
    GEN_ADMIN_CONFIG: kPaths.adminConfig,
    GEN_LOG_FILE: g.logFile || path.join(baseDir, 'provisioning.log'),
    GEN_K8S_SECRET_NAME: g.k8sSecretName || 'kafka-server-side-credentials',
  };
  if (g.kubeconfigPath) env.KUBECONFIG = g.kubeconfigPath;
  if (!env.TERM) env.TERM = 'dumb';
  const sites = req ? getSitesForRequest(req) : getSitesFromConfig();
  if (sites && sites.length > 0) {
    env.GEN_OCP_SITES = sites.map((s) => `${s.ocContext}:${s.namespace}`).join(',');
  }
  const st = getEnvironmentsState();
  if (st.active && st.filePath) {
    env.GEN_ENVIRONMENTS_JSON = st.filePath;
    if (req && req.session) {
      const id = req.session.activeEnvironmentId || st.defaultId;
      if (id) env.GEN_ACTIVE_ENV_ID = String(id);
    }
  }
  // Same bootstrap string as /api/create-topic and /api/topics (getKafkaTopicsEnv); avoids gen.sh hardcoded CWDC/TLS2 when environments.json has no bootstrapServers
  const portalBootstrap = getBootstrapServersForRequest(req);
  if (portalBootstrap && String(portalBootstrap).trim()) {
    env.GEN_KAFKA_BOOTSTRAP = String(portalBootstrap).trim();
  }
  return env;
}

// Input validation: reduce risk of injection / overflow when passing to gen.sh env
const SAFE_NAME_REGEX = /^[a-zA-Z0-9_.-]+$/;
const ENVIRONMENT_ID_REGEX = /^[a-zA-Z0-9_-]+$/;
/** Legacy multi-namespace (gen.sites[]): login / header use ids lns-0, lns-1, … */
const LEGACY_SITE_ID_REGEX = /^lns-(\d+)$/;
const MAX_USERNAME_LEN = 256;
const MAX_TOPIC_LEN = 512;
const MAX_SYSTEM_NAME_LEN = 128;
const MAX_REMOVE_USERS = 100;

function validateSafeName(value, label, maxLen) {
  if (typeof value !== 'string') return `${label} must be a string`;
  const s = value.trim();
  if (!s) return `${label} is required`;
  if (s.length > (maxLen || MAX_USERNAME_LEN)) return `${label} must be at most ${maxLen || MAX_USERNAME_LEN} characters`;
  if (!SAFE_NAME_REGEX.test(s)) return `${label} may only contain letters, numbers, underscore, hyphen, and period`;
  return null;
}

// Validate config and gen.sh before running (for production tracing)
function validateGenReady() {
  if (!config) loadConfig();
  const scriptPath = config.gen?.scriptPath;
  if (!scriptPath) throw new Error('Config gen.scriptPath is not set');
  if (!fs.existsSync(scriptPath)) throw new Error(`gen.sh not found at ${scriptPath}`);
  const baseDir = config.gen?.baseDir;
  if (!baseDir) throw new Error('Config gen.baseDir is not set');
  return { scriptPath, baseDir };
}

// Consistent error response and logging for API routes (production tracing)
function apiError(res, route, err, options = {}) {
  const { status = 500, step, phase, stderr, stdout, code, tasks } = options;
  const errorMessage = err && (err.message || String(err));
  const payload = { ok: false, error: errorMessage };
  if (step) payload.step = step;
  if (phase) payload.phase = phase;
  if (stderr != null) {
    const s = typeof stderr === 'string' ? stderr.slice(-3000) : stderr;
    payload.stderr = typeof s === 'string' ? stripAnsi(s) : s;
  }
  if (stdout != null) {
    const s = typeof stdout === 'string' ? stdout.slice(-1500) : stdout;
    payload.stdout = typeof s === 'string' ? stripAnsi(s) : s;
  }
  if (code != null) payload.exitCode = code;
  if (Array.isArray(tasks) && tasks.length) payload.tasks = tasks;
  const logLine = `[${route}] ${status} ${step || ''} ${phase || ''} code=${code ?? '?'} ${errorMessage || ''}`.trim();
  console.error(logLine);
  if (stderr && typeof stderr === 'string' && stderr.trim()) console.error('[stderr]', stderr.trim().slice(-500));
  if (!res.headersSent) res.status(status).json(payload);
}

function runGen(envOverrides, req) {
  if (!config) loadConfig();
  const scriptPath = config.gen?.scriptPath;
  if (!scriptPath || !fs.existsSync(scriptPath)) {
    return Promise.reject(new Error(`gen.sh not found at ${scriptPath}`));
  }
  const env = { ...getBaseEnv(req), ...envOverrides };
  const genCwd = getGenCwd() || path.dirname(path.resolve(scriptPath));
  return new Promise((resolve, reject) => {
    const proc = spawn(SHELL_CMD, [scriptPath], {
      cwd: genCwd,
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', (d) => { stdout += d.toString(); });
    proc.stderr.on('data', (d) => { stderr += d.toString(); });
    proc.on('close', (code) => resolve({ code, stdout, stderr }));
    proc.on('error', reject);
  });
}

// Like runGen but calls onLine(line) for each line of stdout (for progress streaming). Still returns { code, stdout, stderr }.
// Optional onStderrLine(line) for live stderr (e.g. attach tail to current task).
function runGenStream(envOverrides, onLine, req, onStderrLine) {
  if (!config) loadConfig();
  const scriptPath = config.gen?.scriptPath;
  if (!scriptPath || !fs.existsSync(scriptPath)) {
    return Promise.reject(new Error(`gen.sh not found at ${scriptPath}`));
  }
  const env = { ...getBaseEnv(req), ...envOverrides };
  const genCwd = getGenCwd() || path.dirname(path.resolve(scriptPath));
  return new Promise((resolve, reject) => {
    const proc = spawn(SHELL_CMD, [scriptPath], {
      cwd: genCwd,
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let buf = '';
    let errBuf = '';
    proc.stdout.on('data', (d) => {
      const s = buf + d.toString();
      const lines = s.split(/\r?\n/);
      buf = lines.pop() || '';
      for (const line of lines) if (line.trim() && onLine) onLine(line);
      stdout += d.toString();
    });
    proc.stderr.on('data', (d) => {
      stderr += d.toString();
      if (!onStderrLine) return;
      errBuf += d.toString();
      const lines = errBuf.split(/\r?\n/);
      errBuf = lines.pop() || '';
      for (const line of lines) if (line.trim()) onStderrLine(line);
    });
    proc.on('close', (code) => {
      if (onStderrLine && errBuf.trim()) onStderrLine(errBuf);
      resolve({ code, stdout, stderr });
    });
    proc.on('error', reject);
  });
}

// Extract progress step from gen.sh status_msg output like " [PROCESSING] Validating Topic..."
function parseProgressLine(line) {
  const plain = stripAnsi(String(line));
  const m = plain.match(/\[PROCESSING\]\s*(.+?)(\.\.\.)?$/);
  if (m) return m[1].trim();
  if (/\u2713|DONE|✅/.test(plain)) return null; // done marker, keep previous step
  return null;
}

/** Track gen.sh [PROCESSING] steps for streaming + error reports (which step failed). */
function createGenTaskAccumulator() {
  const tasks = [];
  let runningIdx = -1;
  return {
    onStdoutLine(line) {
      const lbl = parseProgressLine(line);
      if (!lbl) return;
      if (runningIdx >= 0 && tasks[runningIdx].label === lbl && tasks[runningIdx].status === 'running') return;
      if (runningIdx >= 0 && tasks[runningIdx].status === 'running') tasks[runningIdx].status = 'ok';
      tasks.push({ id: `step-${tasks.length + 1}`, label: lbl, status: 'running' });
      runningIdx = tasks.length - 1;
    },
    onStderrLine(line) {
      const plain = stripAnsi(line).trim();
      if (!plain || runningIdx < 0) return;
      if (tasks[runningIdx].status !== 'running') return;
      const cur = tasks[runningIdx].stderrTail || '';
      const next = cur ? `${cur}\n${plain}` : plain;
      tasks[runningIdx].stderrTail = next.length > 900 ? next.slice(-900) : next;
    },
    snapshot() {
      return tasks.map((t) => ({
        id: t.id,
        label: t.label,
        status: t.status,
        ...(t.stderrTail ? { stderrTail: t.stderrTail } : {}),
      }));
    },
    finalize(code, stderr) {
      if (runningIdx >= 0 && tasks[runningIdx].status === 'running') {
        if (code !== 0) {
          tasks[runningIdx].status = 'error';
          if (!tasks[runningIdx].stderrTail && stderr) {
            const tail = stripAnsi(stderr).trim().split(/\r?\n/).filter(Boolean).slice(-4).join(' | ');
            if (tail) tasks[runningIdx].stderrTail = tail.slice(0, 800);
          }
        } else {
          tasks[runningIdx].status = 'ok';
        }
      }
      return this.snapshot();
    },
  };
}

function buildTaskAccumulatorFromOutput(stdout) {
  const acc = createGenTaskAccumulator();
  const lines = String(stdout || '').split(/\r?\n/);
  for (const line of lines) acc.onStdoutLine(line);
  return acc;
}

// Run a one-off shell command with base env (for list topics / list users)
// cwd = baseDir so relative paths and Kafka config work
function runShell(cmd, envOverrides = {}, req) {
  if (!config) loadConfig();
  const env = { ...getBaseEnv(req), ...envOverrides };
  const baseDir = config.gen?.baseDir || process.env.GEN_BASE_DIR || '/tmp';
  const cwd = path.isAbsolute(baseDir) ? baseDir : path.resolve(process.cwd(), baseDir);
  return new Promise((resolve, reject) => {
    const proc = spawn(SHELL_CMD, ['-c', cmd], { env, cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', (d) => { stdout += d.toString(); });
    proc.stderr.on('data', (d) => { stderr += d.toString(); });
    proc.on('close', (code) => resolve({ code, stdout, stderr }));
    proc.on('error', reject);
  });
}

// Run a script with argv (so $0 inside script is the script path — required for Kafka bin scripts)
function runShellScript(scriptPath, args, envOverrides = {}, req) {
  if (!config) loadConfig();
  const env = { ...getBaseEnv(req), ...envOverrides };
  const baseDir = config.gen?.baseDir || process.env.GEN_BASE_DIR || '/tmp';
  const cwd = path.isAbsolute(baseDir) ? baseDir : path.resolve(process.cwd(), baseDir);
  return new Promise((resolve, reject) => {
    const proc = spawn(SHELL_CMD, [scriptPath, ...args], { env, cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', (d) => { stdout += d.toString(); });
    proc.stderr.on('data', (d) => { stderr += d.toString(); });
    proc.on('close', (code) => resolve({ code, stdout, stderr }));
    proc.on('error', reject);
  });
}

// Get bootstrap servers from admin config file or config.gen.bootstrapServers
function getBootstrapServers() {
  const g = config?.gen || {};
  if (g.bootstrapServers) return g.bootstrapServers;
  const adminPath = g.adminConfig || path.join(g.baseDir || '', 'configs/kafka-client-master.properties');
  try {
    const content = fs.readFileSync(adminPath, 'utf8');
    const m = content.match(/bootstrap\.servers\s*=\s*(.+)/);
    if (m) return m[1].trim();
  } catch (_) {}
  return process.env.GEN_BOOTSTRAP || 'localhost:9092';
}

function getEnvironmentsConfigPath() {
  if (!config) return null;
  const sec = config.server?.environments;
  if (!sec || sec.enabled !== true) return null;
  if (sec.derivedSyncPath) return sec.derivedSyncPath;
  const rel = sec.file || 'environments.json';
  const configDir = getConfigDir();
  return path.isAbsolute(rel) ? rel : path.resolve(configDir, rel);
}

function getEnvironmentsState() {
  if (!config) {
    try { loadConfig(); } catch (_) {
      return { active: false, list: [], defaultId: null, filePath: null };
    }
  }
  if (config.server?.environments?.enabled !== true) {
    return { active: false, list: [], defaultId: null, filePath: null };
  }
  const sec = config.server.environments;
  if (sec.inlineData && typeof sec.inlineData === 'object') {
    const data = sec.inlineData;
    if (data.enabled === false) return { active: false, list: [], defaultId: null, filePath: null };
    const list = (Array.isArray(data.environments) ? data.environments : [])
      .filter((e) => e && e.id && e.enabled !== false);
    const defaultId = data.defaultEnvironmentId || (list[0] && list[0].id) || null;
    const filePath = sec.derivedSyncPath || getEnvironmentsConfigPath();
    return {
      active: list.length > 0,
      list,
      defaultId,
      filePath: filePath || null,
    };
  }
  const p = getEnvironmentsConfigPath();
  if (!p || !fs.existsSync(p)) {
    return { active: false, list: [], defaultId: null, filePath: null };
  }
  try {
    const data = JSON.parse(fs.readFileSync(p, 'utf8'));
    if (data.enabled === false) return { active: false, list: [], defaultId: null, filePath: null };
    const list = (Array.isArray(data.environments) ? data.environments : [])
      .filter((e) => e && e.id && e.enabled !== false);
    const defaultId = data.defaultEnvironmentId || (list[0] && list[0].id) || null;
    return {
      active: list.length > 0,
      list,
      defaultId,
      filePath: p,
    };
  } catch (e) {
    console.warn('[environments]', e.message);
    return { active: false, list: [], defaultId: null, filePath: null };
  }
}

function normalizeSiteEntry(s, fallbackName) {
  if (!s || !s.namespace || !s.ocContext) return null;
  return {
    name: s.name || s.ocContext || fallbackName || 'site',
    namespace: String(s.namespace).trim(),
    ocContext: String(s.ocContext).trim(),
  };
}

function sitesFromEnvironmentEntry(entry) {
  if (!entry) return null;
  if (Array.isArray(entry.sites) && entry.sites.length) {
    const out = entry.sites.map((site) => normalizeSiteEntry(site, entry.id)).filter(Boolean);
    return out.length ? out : null;
  }
  if (entry.namespace && entry.ocContext) {
    const one = normalizeSiteEntry(
      { name: entry.ocContext, namespace: entry.namespace, ocContext: entry.ocContext },
      entry.id
    );
    return one ? [one] : null;
  }
  return null;
}

function getSitesForRequest(req) {
  const st = getEnvironmentsState();
  if (st.active && req && req.session) {
    const id = req.session.activeEnvironmentId || st.defaultId;
    const entry = st.list.find((e) => e.id === id) || st.list.find((e) => e.id === st.defaultId) || st.list[0];
    const sites = sitesFromEnvironmentEntry(entry);
    if (sites && sites.length) return sites;
    // Critical: do not fall back to all gen.sites — that merges every cluster/namespace (e.g. DEV+UAT)
    // while the header still shows the selected portal environment, so OCP status would look "wrong".
    console.warn(
      `[environments] Portal env "${id}" has no resolvable sites (check sites[] or namespace/ocContext on this entry). Not using legacy gen.sites.`
    );
    return [];
  }
  const all = getSitesFromConfig();
  if (req && req.session && typeof req.session.legacySiteIndex === 'number' && all && all.length) {
    const idx = req.session.legacySiteIndex;
    if (idx >= 0 && idx < all.length) return [all[idx]];
  }
  return all;
}

function getOcLoginSitesUnion() {
  const st = getEnvironmentsState();
  if (!st.active) return getSitesFromConfig();
  const map = new Map();
  for (const entry of st.list) {
    const sites = sitesFromEnvironmentEntry(entry) || [];
    for (const s of sites) {
      if (s.ocContext && !map.has(s.ocContext)) map.set(s.ocContext, s);
    }
  }
  const arr = Array.from(map.values());
  return arr.length ? arr : getSitesFromConfig();
}

/** Active portal environment row (session + environments enabled), or null. */
function getActiveEnvironmentEntry(req) {
  const st = getEnvironmentsState();
  if (!st.active) return null;
  if (!req || !req.session) return null;
  const id = req.session.activeEnvironmentId || st.defaultId;
  return st.list.find((e) => e.id === id) || st.list.find((e) => e.id === st.defaultId) || st.list[0] || null;
}

/**
 * Kafka command-config paths for this request.
 * - Environments off (or no session env): master kafka.* default files (e.g. kafka-client-master.properties).
 * - Environments on + active env: always kafka-client-master-{envId}.properties and kafka-client-{envId}.properties
 *   under baseDir/configs/ — no fallback to unsuffixed names. Optional per-entry adminPropertiesFile / clientConfig etc. overrides.
 */
function resolveKafkaCommandConfigPaths(req) {
  if (!config) loadConfig();
  const g = config.gen || {};
  const baseDir = path.resolve(g.baseDir || process.env.GEN_BASE_DIR || '/opt/kafka-usermgmt');
  const defaultAdmin = g.adminConfig
    ? (path.isAbsolute(g.adminConfig) ? g.adminConfig : path.join(baseDir, g.adminConfig))
    : path.join(baseDir, 'configs', 'kafka-client-master.properties');
  const defaultClient = g.clientConfig
    ? (path.isAbsolute(g.clientConfig) ? g.clientConfig : path.join(baseDir, g.clientConfig))
    : path.join(baseDir, 'configs', 'kafka-client.properties');

  const st = getEnvironmentsState();
  const entry = getActiveEnvironmentEntry(req);
  if (!st.active || !entry) {
    return { adminConfig: defaultAdmin, clientConfig: defaultClient };
  }

  const configsDir = path.join(baseDir, 'configs');
  const safeEnvId = String(entry.id || '').trim().replace(/[^a-zA-Z0-9_-]/g, '');
  if (!safeEnvId) {
    console.warn('[kafka-config] environment id missing or invalid; using default kafka property files');
    return { adminConfig: defaultAdmin, clientConfig: defaultClient };
  }

  const conventionAdmin = path.join(configsDir, `kafka-client-master-${safeEnvId}.properties`);
  const conventionClient = path.join(configsDir, `kafka-client-${safeEnvId}.properties`);

  let admin = conventionAdmin;
  if (typeof entry.adminPropertiesFile === 'string' && entry.adminPropertiesFile.trim()) {
    const base = path.basename(entry.adminPropertiesFile.trim());
    if (base && base !== '.' && base !== '..') admin = path.join(configsDir, base);
  } else if (typeof entry.adminConfig === 'string' && entry.adminConfig.trim()) {
    const rel = entry.adminConfig.trim();
    const candidate = path.isAbsolute(rel) ? rel : path.join(baseDir, rel.replace(/^[\\/]+/, ''));
    const resolved = path.resolve(candidate);
    const baseResolved = path.resolve(baseDir);
    if (resolved === baseResolved || resolved.startsWith(`${baseResolved}${path.sep}`)) {
      admin = resolved;
    }
  }

  let client = conventionClient;
  if (typeof entry.clientPropertiesFile === 'string' && entry.clientPropertiesFile.trim()) {
    const base = path.basename(entry.clientPropertiesFile.trim());
    if (base && base !== '.' && base !== '..') client = path.join(configsDir, base);
  } else if (typeof entry.clientConfig === 'string' && entry.clientConfig.trim()) {
    const rel = entry.clientConfig.trim();
    const candidate = path.isAbsolute(rel) ? rel : path.join(baseDir, rel.replace(/^[\\/]+/, ''));
    const resolved = path.resolve(candidate);
    const baseResolved = path.resolve(baseDir);
    if (resolved === baseResolved || resolved.startsWith(`${baseResolved}${path.sep}`)) {
      client = resolved;
    }
  }

  return { adminConfig: admin, clientConfig: client };
}

function getBootstrapServersForRequest(req) {
  if (!config) loadConfig();
  const st = getEnvironmentsState();
  if (st.active && req && req.session) {
    const id = req.session.activeEnvironmentId || st.defaultId;
    const entry = st.list.find((e) => e.id === id) || st.list[0];
    if (entry && typeof entry.bootstrapServers === 'string' && entry.bootstrapServers.trim()) {
      return entry.bootstrapServers.trim();
    }
  }
  const g = config.gen || {};
  if (g.bootstrapServers) return g.bootstrapServers;
  const { adminConfig } = resolveKafkaCommandConfigPaths(req);
  try {
    const content = fs.readFileSync(adminConfig, 'utf8');
    const m = content.match(/bootstrap\.servers\s*=\s*(.+)/);
    if (m) return m[1].trim();
  } catch (_) { /* missing file */ }
  return process.env.GEN_BOOTSTRAP || 'localhost:9092';
}

// Avoid 404 in console: no favicon
app.get('/favicon.ico', (req, res) => res.status(204).end());

// Static: long cache for assets; never cache HTML (session-sensitive UI, back/forward after logout).
app.use(express.static(STATIC_DIR, {
  maxAge: 3600000,
  setHeaders(res, filePath) {
    if (/\.html$/i.test(filePath)) {
      res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, private');
    }
  },
}));

app.get('/api/version', (req, res) => {
  const sha = process.env.GIT_COMMIT || '';
  const gitSha = typeof sha === 'string' && sha.length >= 7 ? sha.slice(0, 7) : '';
  res.json({ ok: true, version: APP_VERSION, ...(gitSha ? { gitSha } : {}) });
});

app.get('/api/config', (req, res) => {
  try {
    if (!config) loadConfig();
    res.json({ ok: true, version: APP_VERSION, gen: { baseDir: config.gen?.baseDir, kafkaBin: config.gen?.kafkaBin } });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

// UTC → GMT+7 for audit log display (server stores UTC via toISOString).
function toGmt7(isoUtc) {
  if (!isoUtc || typeof isoUtc !== 'string') return null;
  try {
    const d = new Date(isoUtc);
    if (Number.isNaN(d.getTime())) return null;
    const gmt7 = new Date(d.getTime() + 7 * 60 * 60 * 1000);
    const y = gmt7.getUTCFullYear();
    const m = String(gmt7.getUTCMonth() + 1).padStart(2, '0');
    const day = String(gmt7.getUTCDate()).padStart(2, '0');
    const h = String(gmt7.getUTCHours()).padStart(2, '0');
    const min = String(gmt7.getUTCMinutes()).padStart(2, '0');
    const s = String(gmt7.getUTCSeconds()).padStart(2, '0');
    return `${y}-${m}-${day} ${h}:${min}:${s}`;
  } catch (_) { return null; }
}
function toGmt7Date(isoUtc) {
  const t = toGmt7(isoUtc);
  return t ? t.slice(0, 10) : null;
}

// Normalize audit entry to one or more rows (1 user per row for remove-user with multiple users; same time for the batch).
function normalizeAuditEntries(raw) {
  const time = raw.time || null;
  const action = raw.action || null;
  const who = raw.user || null;
  const d = raw.detail || {};
  const system = d.systemName != null ? String(d.systemName) : null;
  const topic = d.topic != null ? String(d.topic) : null;
  if (action === 'create-topic' && (topic || (d && d.topic))) {
    const t = topic || (d && d.topic);
    return [{ time, action, who, system: null, topic: t, target: t }];
  }
  if (action === 'remove-user' && Array.isArray(d.users) && d.users.length > 0) {
    return d.users.map((u) => ({ time, action, who, system: null, topic: null, target: String(u) }));
  }
  if (action === 'add-acl-existing' && (d.username != null || d.topic != null)) {
    return [{ time, action, who, system: null, topic: d.topic != null ? String(d.topic) : null, target: d.username != null ? String(d.username) : null }];
  }
  const target = d.username != null ? String(d.username) : null;
  return [{ time, action, who, system, topic, target }];
}

// GET /api/audit-log — entries from audit.log and optionally gen.auditLogPath (CLI). Optional from, to YYYY-MM-DD in GMT+7.
app.get('/api/audit-log', (req, res) => {
  if (!config) try { loadConfig(); } catch (_) {}
  const dataDir = getDataDir();
  const from = (req.query.from || '').trim();
  const to = (req.query.to || '').trim();
  let raw = [];
  if (dataDir) {
    const logPath = path.join(dataDir, 'audit.log');
    if (fs.existsSync(logPath)) {
      try {
        const lines = fs.readFileSync(logPath, 'utf8').split('\n').filter(Boolean);
        raw = lines.map((line) => {
          try { return JSON.parse(line); } catch (_) { return null; }
        }).filter(Boolean);
      } catch (_) {}
    }
  }
  if (config && config.gen && config.gen.auditLogPath) {
    const extraPath = path.resolve(config.gen.auditLogPath);
    if (fs.existsSync(extraPath) && fs.statSync(extraPath).isFile()) {
      try {
        const lines = fs.readFileSync(extraPath, 'utf8').split('\n').filter(Boolean);
        lines.forEach((line) => {
          try {
            const j = JSON.parse(line);
            if (j && (j.time || j.action)) raw.push(j);
          } catch (_) {}
        });
      } catch (_) {}
    }
  }
  let entries = raw.flatMap(normalizeAuditEntries);
  if (from) entries = entries.filter((e) => e.time && toGmt7Date(e.time) >= from);
  if (to) entries = entries.filter((e) => e.time && toGmt7Date(e.time) <= to);
  entries.sort((a, b) => (b.time || '').localeCompare(a.time || ''));
  entries = entries.map((e) => ({ ...e, time: toGmt7(e.time) || e.time }));
  res.json({ ok: true, entries });
});

// Scan a directory for .enc files and return list of { filename, datetime (ISO), date } for merge into download history (CLI-created packs)
function sweepEncFilesFromDir(dir) {
  const out = [];
  if (!dir || !fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return out;
  try {
    const names = fs.readdirSync(dir);
    for (const name of names) {
      if (!name.endsWith('.enc')) continue;
      const fp = path.join(dir, name);
      if (!fs.statSync(fp).isFile()) continue;
      const stat = fs.statSync(fp);
      const datetime = stat.mtime ? stat.mtime.toISOString() : new Date().toISOString();
      out.push({ filename: name, datetime, date: datetime.slice(0, 10), packName: name.replace(/\.enc$/i, ''), user: null });
    }
  } catch (_) {}
  return out;
}

// GET /api/download-history — by day (only days with activity), with download links. Includes packs from download-history.json (web) and sweep of user_output / downloadDir (CLI).
app.get('/api/download-history', (req, res) => {
  const dataDir = getDataDir();
  let list = [];
  if (dataDir) {
    const filePath = path.join(dataDir, 'download-history.json');
    if (fs.existsSync(filePath)) {
      try {
        list = JSON.parse(fs.readFileSync(filePath, 'utf8'));
      } catch (_) {}
    }
  }
  if (!Array.isArray(list)) list = [];
  const seen = new Set(list.map((item) => (item.filename || '').toLowerCase()));
  if (config) {
    try {
      const g = config.gen || {};
      const baseDir = g.baseDir ? path.resolve(g.baseDir) : null;
      const downloadDir = g.downloadDir ? path.resolve(g.downloadDir) : null;
      for (const dir of [downloadDir, baseDir ? path.join(baseDir, 'user_output') : null, baseDir].filter(Boolean)) {
        for (const item of sweepEncFilesFromDir(dir)) {
          if (item.filename && !seen.has(item.filename.toLowerCase())) {
            seen.add(item.filename.toLowerCase());
            list.push(item);
          }
        }
      }
    } catch (_) {}
  }
  const byDay = {};
  list.forEach((item) => {
    const d = item.date || item.datetime?.slice(0, 10);
    if (!d) return;
    if (!byDay[d]) byDay[d] = [];
    byDay[d].push({
      datetime: item.datetime,
      filename: item.filename,
      packName: item.packName,
      user: item.user,
      downloadPath: item.filename ? `/api/download/${encodeURIComponent(item.filename)}` : null,
    });
  });
  Object.keys(byDay).sort().reverse().forEach((d) => {
    byDay[d].sort((a, b) => (b.datetime || '').localeCompare(a.datetime || ''));
  });
  const sortedDays = Object.keys(byDay).sort().reverse();
  res.json({ ok: true, byDay, days: sortedDays });
});

// Resolve kafka-topics.sh path and admin config (shared by list and create)
function getKafkaTopicsEnv(req) {
  if (!config) loadConfig();
  const g = config.gen || {};
  const baseDir = path.resolve(g.baseDir || g.rootDir || process.env.BASE_HOST || process.cwd());
  const kafkaBin = g.kafkaBin ? (path.isAbsolute(g.kafkaBin) ? g.kafkaBin : path.join(baseDir, g.kafkaBin)) : path.join(baseDir, 'kafka_2.13-3.6.1', 'bin');
  const { adminConfig } = resolveKafkaCommandConfigPaths(req);
  const bootstrap = getBootstrapServersForRequest(req);
  const scriptPath = path.join(kafkaBin, 'kafka-topics.sh');
  const kafkaAclsPath = path.join(kafkaBin, 'kafka-acls.sh');
  return { scriptPath, adminConfig, bootstrap, kafkaAclsPath };
}

// GET /api/topics — list Kafka topics (for wizard dropdown; calls kafka-topics.sh --list)
app.get('/api/topics', (req, res) => {
  try {
    if (!config) loadConfig();
  } catch (e) {
    return res.status(500).json({
      ok: false,
      error: e.message,
      setupPageUrl: `${clientFacingBaseUrl(req)}/setup.html`,
    });
  }
  const { scriptPath, adminConfig, bootstrap } = getKafkaTopicsEnv(req);
  const topicsSetupUrl = `${clientFacingBaseUrl(req)}/setup.html`;
  runShellScript(scriptPath, ['--bootstrap-server', bootstrap, '--command-config', adminConfig, '--list'], {}, req)
    .then(({ code, stdout, stderr }) => {
      const topics = (stdout || '').split('\n').map((t) => t.trim()).filter(Boolean);
      if (code !== 0 && (stderr || stdout)) {
        const msg = (stderr || stdout).trim().slice(0, 500);
        console.error('[topics]', code, msg);
        const payload = {
          ok: false,
          error: 'List topics failed',
          detail: msg,
          setupPageUrl: topicsSetupUrl,
        };
        if (/Couldn't resolve server|DNS resolution failed|host1|host2|bootstrap\.servers/i.test(msg)) {
          payload.hint = 'Set gen.bootstrapServers in Docker/web.config.json to your real Kafka broker host:port (e.g. broker1:443,broker2:443). Replace placeholder host1:443,host2:443.';
        }
        return res.status(500).json(payload);
      }
      const payload = { ok: true, topics };
      if (topics.length === 0) {
        payload.hint = 'List ว่าง: ตรวจสอบ bootstrapServers ใน config และว่า container ไปถึง Kafka ได้ (เครือข่าย/ไฟร์วอลล์)';
        if (stderr || stdout) payload.detail = (stderr || stdout).trim().slice(0, 300);
      }
      res.json(payload);
    })
    .catch((err) => {
      console.error('[topics]', err.message);
      res.status(500).json({ ok: false, error: err.message, setupPageUrl: topicsSetupUrl });
    });
});

// POST /api/create-topic — create Kafka topic (for "Create Topic & Onboard User" flow).
// Uses broker default for partitions and replication factor (rack-aware placement). Do not pass --partitions/--replication-factor.
app.post('/api/create-topic', (req, res) => {
  try {
    if (!config) loadConfig();
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message });
  }
  const { topic } = req.body || {};
  const errors = [];
  const topicErr = validateSafeName(topic, 'topic', MAX_TOPIC_LEN);
  if (topicErr) errors.push(topicErr);
  if (errors.length) return res.status(400).json({ ok: false, errors });

  const topicName = String(topic).trim();
  const { scriptPath, adminConfig, bootstrap } = getKafkaTopicsEnv(req);
  const args = [
    '--create',
    '--topic', topicName,
    '--bootstrap-server', bootstrap,
    '--command-config', adminConfig,
  ];
  runShellScript(scriptPath, args, {}, req)
    .then(({ code, stdout, stderr }) => {
      if (code === 0) {
        appendAuditLog(req, 'create-topic', { topic: topicName });
        return res.json({
          ok: true,
          message: 'Topic created successfully (broker default partitions/replication).',
          topic: topicName,
          output: (stdout || '').trim().slice(-500),
        });
      }
      const msg = (stderr || stdout || '').trim().slice(0, 800);
      const alreadyExists = /already exists|TopicExistsException/i.test(msg);
      const status = alreadyExists ? 409 : 500;
      const payload = { ok: false, error: alreadyExists ? 'Topic already exists' : 'Create topic failed', detail: msg };
      if (alreadyExists) payload.topic = topicName;
      res.status(status).json(payload);
    })
    .catch((err) => {
      console.error('[create-topic]', err.message);
      res.status(500).json({ ok: false, error: err.message });
    });
});

// GET /api/list-acls?username=xxx — list current ACLs for principal User:xxx (for "Add ACL to existing user" summary)
app.get('/api/list-acls', (req, res) => {
  try {
    if (!config) loadConfig();
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message });
  }
  const username = (req.query.username || '').trim();
  const err = validateSafeName(username, 'username', MAX_USERNAME_LEN);
  if (err) return res.status(400).json({ ok: false, error: err });
  if (!username) return res.status(400).json({ ok: false, error: 'username required' });
  const { kafkaAclsPath, adminConfig, bootstrap } = getKafkaTopicsEnv(req);
  const args = ['--bootstrap-server', bootstrap, '--command-config', adminConfig, '--list', '--principal', `User:${username}`];
  runShellScript(kafkaAclsPath, args, {}, req)
    .then(({ code, stdout, stderr }) => {
      if (code !== 0) {
        const msg = (stderr || stdout || '').trim().slice(0, 800);
        return res.status(500).json({ ok: false, error: 'List ACLs failed', detail: msg });
      }
      res.json({ ok: true, aclList: (stdout || '').trim() });
    })
    .catch((err) => {
      console.error('[list-acls]', err.message);
      res.status(500).json({ ok: false, error: err.message });
    });
});

// POST /api/add-acl-existing-user — add topic/ACL for existing user (no new credential). Body: { username, topic, acl: '1'|'2'|'3' }.
app.post('/api/add-acl-existing-user', (req, res) => {
  try {
    validateGenReady();
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message });
  }
  const { username, topic, acl } = req.body || {};
  const errors = [];
  const e1 = validateSafeName(username, 'username', MAX_USERNAME_LEN);
  if (e1) errors.push(e1);
  const e2 = validateSafeName(topic, 'topic', MAX_TOPIC_LEN);
  if (e2) errors.push(e2);
  if (errors.length) return res.status(400).json({ ok: false, errors });
  const aclVal = (acl === 'read' || acl === '1') ? '1' : (acl === 'client' || acl === '2') ? '2' : '3';
  const env = {
    GEN_NONINTERACTIVE: '1',
    GEN_MODE: '5',
    GEN_KAFKA_USER: String(username).trim(),
    GEN_TOPIC_NAME: String(topic).trim(),
    GEN_ACL: aclVal,
  };
  runGen(env, req)
    .then(({ code, stdout, stderr }) => {
      if (code !== 0) {
        const raw = (stderr || stdout || '').trim().slice(0, 1000);
        const msg = stripAnsi(raw);
        return res.status(500).json({ ok: false, error: 'Add ACL failed', detail: msg, step: 'add-acl-existing', exitCode: code });
      }
      appendAuditLog(req, 'add-acl-existing', { username: String(username).trim(), topic: String(topic).trim() });
      res.json({ ok: true, message: 'ACL added for existing user.' });
    })
    .catch((err) => {
      console.error('[add-acl-existing-user]', err.message);
      res.status(500).json({ ok: false, error: err.message });
    });
});

// GET /api/users — list Kafka users from OCP secret (all configured sites, merged)
const SYSTEM_USERS_REGEX = /^(kafka|schema_registry|kafka_connect|control_center|client|admin|user1|user2|an-api-key)$/;

// Returns [{ name, namespace, ocContext }, ...]. Supports gen.sites (both sites) or legacy single gen.namespace + gen.ocContext.
function getSitesFromConfig() {
  if (!config) loadConfig();
  const g = config.gen || {};
  if (Array.isArray(g.sites) && g.sites.length > 0) {
    return g.sites.map((s) => ({
      name: s.name || s.ocContext || 'site',
      namespace: s.namespace,
      ocContext: s.ocContext
    })).filter((s) => s.namespace && s.ocContext);
  }
  // Legacy single-site: gen.namespace + gen.ocContext or env — no baked-in cluster names (must be set explicitly).
  const ns = String(g.namespace || process.env.GEN_NAMESPACE || process.env.GEN_NS_CWDC || '').trim();
  const ctx = String(g.ocContext || process.env.GEN_OC_CONTEXT || process.env.GEN_OCP_CTX_CWDC || '').trim();
  if (ns && ctx) return [{ name: ctx, namespace: ns, ocContext: ctx }];
  return [];
}

// Run oc login for each site when gen.ocAutoLogin is set.
// รองรับ: (1) Token จาก gen.ocLoginToken / env OC_LOGIN_TOKEN (2) User+Password จาก gen.ocLoginUser+ocLoginPassword / env OC_LOGIN_USER+OC_LOGIN_PASSWORD — ฝังใน config ได้เลย
// Kubeconfig must be writable.
function runOcLoginIfConfigured() {
  if (!config) loadConfig();
  const g = config.gen || {};
  if (!g.ocAutoLogin || !g.kubeconfigPath) return Promise.resolve();
  const servers = g.ocLoginServers || {};
  if (typeof servers !== 'object' || Object.keys(servers).length === 0) {
    console.warn('[oc-auto-login] gen.ocLoginServers ไม่ได้ตั้ง ข้าม auto login');
    return Promise.resolve();
  }
  const sites = getOcLoginSitesUnion();
  const tokensConf = g.ocLoginTokens || {};
  const singleToken = g.ocLoginToken || process.env.OC_LOGIN_TOKEN;
  const singleUser = g.ocLoginUser || process.env.OC_LOGIN_USER;
  const singlePassword = g.ocLoginPassword || process.env.OC_LOGIN_PASSWORD;

  function getToken(site) {
    return tokensConf[site.ocContext] || tokensConf[site.name] || singleToken ||
      process.env['OC_LOGIN_TOKEN_' + (site.ocContext || '').toUpperCase().replace(/-/g, '_')];
  }
  function getUser(site) {
    const creds = g.ocLoginCredentials && g.ocLoginCredentials[site.ocContext];
    if (creds && creds.user) return creds.user;
    return singleUser || process.env['OC_LOGIN_USER_' + (site.ocContext || '').toUpperCase().replace(/-/g, '_')];
  }
  function getPassword(site) {
    const creds = g.ocLoginCredentials && g.ocLoginCredentials[site.ocContext];
    if (creds && creds.password) return creds.password;
    return singlePassword || process.env['OC_LOGIN_PASSWORD_' + (site.ocContext || '').toUpperCase().replace(/-/g, '_')];
  }

  const methodStatus = sites.map((s) => {
    if (getToken(s)) return `${s.ocContext}:token`;
    if (getUser(s) && getPassword(s)) return `${s.ocContext}:user/password`;
    return `${s.ocContext}:missing`;
  }).join(', ');
  console.log('[oc-auto-login] credentials:', methodStatus);

  let chain = Promise.resolve();
  for (const site of sites) {
    const serverUrl = servers[site.ocContext] || servers[site.name];
    if (!serverUrl) continue;
    const token = getToken(site);
    const user = getUser(site);
    let password = getPassword(site);
    if (password && String(password).startsWith('enc:')) {
      password = decryptOcCredential(password, process.env.OC_CREDENTIALS_KEY);
      if (!password) console.warn('[oc-auto-login] ไม่สามารถถอดรหัส ocLoginPassword ได้ — ตรวจสอบ OC_CREDENTIALS_KEY');
    }

    if (token) {
      chain = chain.then(() => {
        return runShell(
          `oc login --server="${serverUrl.replace(/"/g, '\\"')}" --token="$OC_LOGIN_TOKEN_CURRENT" --insecure-skip-tls-verify=true 2>&1`,
          { KUBECONFIG: g.kubeconfigPath, OC_LOGIN_TOKEN_CURRENT: String(token) }
        ).then(({ code, stdout, stderr }) => {
          if (code === 0) {
            console.log('[oc-auto-login]', site.ocContext || site.name, 'OK (token)');
            return;
          }
          const msg = (stderr || stdout || '').trim().slice(0, 300);
          console.error('[oc-auto-login]', site.ocContext || site.name, 'failed:', msg);
        });
      });
    } else if (user && password) {
      chain = chain.then(() => {
        return runShell(
          `oc login --server="${serverUrl.replace(/"/g, '\\"')}" -u "$OC_LOGIN_USER_CURRENT" -p "$OC_LOGIN_PASSWORD_CURRENT" --insecure-skip-tls-verify=true 2>&1`,
          {
            KUBECONFIG: g.kubeconfigPath,
            OC_LOGIN_USER_CURRENT: String(user),
            OC_LOGIN_PASSWORD_CURRENT: String(password),
          }
        ).then(({ code, stdout, stderr }) => {
          if (code === 0) {
            console.log('[oc-auto-login]', site.ocContext || site.name, 'OK (user/password)');
            return;
          }
          const msg = (stderr || stdout || '').trim().slice(0, 300);
          console.error('[oc-auto-login]', site.ocContext || site.name, 'failed:', msg);
        });
      });
    } else {
      console.warn('[oc-auto-login] ไม่มี credentials สำหรับ', site.ocContext, '— ตั้ง gen.ocLoginUser + gen.ocLoginPassword หรือ OC_LOGIN_USER + OC_LOGIN_PASSWORD');
    }
  }
  return chain;
}

// Check if oc session for context is still valid (not expired). Uses KUBECONFIG from config.
function checkOcSession(contextName) {
  if (!config) loadConfig();
  const g = config.gen || {};
  const kubeconfig = g.kubeconfigPath || process.env.KUBECONFIG;
  if (!kubeconfig || !contextName) return Promise.resolve(true);
  const env = getBaseEnv();
  return runShell(
    `oc whoami --context="${String(contextName).replace(/"/g, '\\"')}" 2>&1`,
    env
  ).then(({ code, stdout, stderr }) => {
    if (code === 0 && (stdout || '').trim()) return true;
    const msg = (stderr || stdout || '').trim();
    const isAuthError = /provide credentials|Unauthorized|token.*expired|expired|invalid/i.test(msg);
    if (isAuthError) console.warn('[oc-session-check]', contextName, 'expired or invalid:', msg.slice(0, 200));
    return false;
  });
}

// Ensure all OC contexts used by sites are valid. If any fail (e.g. expired), run oc login once then return.
// Prevents user-facing "credentials" errors by re-login before the next API call.
function ensureOcSessions() {
  if (!config) loadConfig();
  const g = config.gen || {};
  if (!g.ocAutoLogin || !g.kubeconfigPath) return Promise.resolve();
  const sites = getOcLoginSitesUnion();
  if (!sites.length) return Promise.resolve();
  return Promise.all(sites.map((site) => checkOcSession(site.ocContext)))
    .then((results) => {
      const allOk = results.every(Boolean);
      if (allOk) return;
      console.warn('[oc-session-check] บาง context หมดอายุหรือไม่ valid — ทำ auto login ใหม่');
      return runOcLoginIfConfigured();
    });
}

let ocSessionRefreshTimer = null;
// When ocAutoLogin is enabled, periodically verify sessions and re-login if expired (session ต่อเนื่องไร้รอยต่อ).
function startOcSessionRefreshInterval() {
  if (ocSessionRefreshTimer) return;
  try {
    if (!config) loadConfig();
  } catch (_) { return; }
  const g = config.gen || {};
  if (!g.ocAutoLogin || !g.kubeconfigPath || !(g.ocLoginServers && Object.keys(g.ocLoginServers).length)) return;
  const intervalMs = Math.max(5 * 60 * 1000, (g.ocSessionCheckIntervalMinutes || 10) * 60 * 1000);
  ocSessionRefreshTimer = setInterval(() => {
    ensureOcSessions().catch((err) => console.error('[oc-session-check]', err.message));
  }, intervalMs);
  console.log('[oc-session-check] เปิด periodic check ทุก', Math.round(intervalMs / 60000), 'นาที');
}

function clearOcSessionRefreshInterval() {
  if (ocSessionRefreshTimer) {
    clearInterval(ocSessionRefreshTimer);
    ocSessionRefreshTimer = null;
  }
}

function parseUsersFromJson(raw) {
  const obj = JSON.parse(raw);
  const all = Array.isArray(obj) ? obj : (typeof obj === 'object' && obj !== null ? Object.keys(obj) : []);
  return all.filter((u) => !SYSTEM_USERS_REGEX.test(String(u))).sort();
}

// Check kubeconfig exists and has the requested context (clear error for "context does not exist")
function ensureOcContext(kubeconfigPath, contextName, envOverrides) {
  if (!kubeconfigPath || !contextName) return Promise.resolve();
  const absPath = path.isAbsolute(kubeconfigPath) ? kubeconfigPath : path.resolve(process.cwd(), kubeconfigPath);
  if (!fs.existsSync(absPath)) {
    return Promise.reject(new Error(
      `ไฟล์ kubeconfig ไม่พบใน container ที่ path: ${kubeconfigPath}. ` +
      'ตรวจสอบ: (1) master.config / web.config มี gen.kubeconfigPath ตรงกับ path ที่ mount (เช่น /opt/kafka-usermgmt/.kube/config) (2) ถ้า .kube อยู่ภายนอก ROOT ให้ mount เป็น -v KUBE_DIR:ROOT/.kube-external:z แล้ว restart container'
    ));
  }
  return runShell(`oc config get-contexts --no-headers 2>&1`, envOverrides).then(({ code, stdout, stderr }) => {
    if (code !== 0) {
      const msg = (stderr || stdout || 'oc config get-contexts failed').trim().slice(0, 400);
      return Promise.reject(new Error(
        `oc ไม่สามารถอ่าน kubeconfig ที่ ${kubeconfigPath}: ${msg}. ` +
        'ตรวจสอบ path และ volume mount แล้ว restart container'
      ));
    }
    const lines = (stdout || '').trim().split(/\n/).filter(Boolean);
    const contextNames = lines.map((line) => {
      const parts = line.trim().split(/\s+/).filter(Boolean);
      return parts[0] === '*' ? (parts[1] || parts[0]) : (parts[0] || '');
    }).filter(Boolean);
    const hasContext = contextNames.includes(contextName);
    if (!hasContext) {
      return Promise.reject(new Error(
        `ใน container ไฟล์ kubeconfig ที่ "${kubeconfigPath}" ไม่มี context "${contextName}". ` +
        `บน host ให้รัน: KUBECONFIG=<path-to-same-file> oc config get-contexts แล้วใช้ไฟล์ที่มี context นี้ หรือแก้ gen.sites / gen.ocContext ใน web.config.json ให้ตรงกับ context ในไฟล์. (context ที่เห็นใน container: ${contextNames.slice(0, 8).join(', ') || 'ไม่มี'})`
      ));
    }
    return Promise.resolve();
  });
}

app.get('/api/users', (req, res) => {
  try {
    if (!config) loadConfig();
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message });
  }
  const g = config.gen || {};
  const secret = g.k8sSecretName || 'kafka-server-side-credentials';
  const sites = getSitesForRequest(req);
  const kubeconfig = g.kubeconfigPath || process.env.KUBECONFIG;
  if (!kubeconfig) {
    return res.status(500).json({
      ok: false,
      error: 'ไม่ได้ตั้ง gen.kubeconfigPath ใน web.config.json',
      detail: 'ให้ตั้ง kubeconfigPath ให้ชี้ไปที่ไฟล์ kubeconfig ใน container (ปกติ /opt/kafka-usermgmt/.kube/config หลัง oc login) — ทุกอย่างอยู่ใต้ ROOT เดียว; ถ้า .kube อยู่ภายนอก ROOT ให้ mount เป็น ROOT/.kube-external แล้ว restart container'
    });
  }
  const envOverrides = { KUBECONFIG: kubeconfig };

  // Ensure OC sessions are valid before listing (re-login if expired) so user does not see credentials error.
  ensureOcSessions()
    .then(() => {
  // Fetch secret from each site; merge users from sites that succeed. If one site fails (e.g. credentials), still return users from the rest.
  const fetchSite = (site) => {
    const script = `oc get secret ${secret} -n ${site.namespace} --context ${site.ocContext} -o jsonpath='{.data.plain-users\\.json}' 2>&1`;
    return runShell(script, envOverrides, req).then(({ code, stdout, stderr }) => {
      if (code !== 0) {
        const msg = (stderr || stdout || 'oc failed').trim().slice(0, 500);
        return { site: site.name, error: msg, users: [] };
      }
      const b64 = (stdout || '').trim().replace(/\s/g, '');
      if (!b64) return { site: site.name, error: 'secret empty or no plain-users.json', users: [] };
      let raw;
      try {
        raw = Buffer.from(b64, 'base64').toString('utf8');
      } catch (e) {
        return { site: site.name, error: e.message, users: [] };
      }
      if (!raw || (!raw.startsWith('{') && !raw.startsWith('['))) {
        return { site: site.name, error: 'secret value is not JSON', users: [] };
      }
      try {
        return { site: site.name, error: null, users: parseUsersFromJson(raw) };
      } catch (e) {
        return { site: site.name, error: e.message, users: [] };
      }
    });
  };
  return Promise.all(sites.map(fetchSite))
    .then((results) => {
      const merged = [...new Set(results.flatMap((r) => r.users))].sort();
      const failed = results.filter((r) => r.error).map((r) => `${r.site}: ${r.error}`);
      if (merged.length === 0 && failed.length > 0) {
        const allFailed = failed.join('; ');
        const isCredentials = /provide credentials|Unauthorized|token.*expired/i.test(allFailed);
        const hint = isCredentials
          ? ' (Token/credentials หมดอายุหรือไม่ถูกต้อง — บน host ที่ mount .kube: รัน oc login ใหม่ให้ครบทุก context ที่ใช้ แล้ว restart container)'
          : '';
        return res.status(500).json({
          ok: false,
          error: 'List users failed' + hint,
          detail: allFailed || 'All sites failed'
        });
      }
      const payload = { ok: true, users: merged, sites: sites.map((s) => s.name) };
      if (failed.length > 0) payload.sitesFailed = failed;
      res.json(payload);
    })
    .catch((err) => {
      console.error('[users]', err.message);
      if (!res.headersSent) {
        res.status(500).json({ ok: false, error: err.message, detail: err.message });
      }
    });
  })
    .catch((err) => {
      console.error('[users] ensureOcSessions:', err.message);
      if (!res.headersSent) {
        res.status(500).json({ ok: false, error: err.message });
      }
    });
});

// Working directory for gen.sh: runtime baseDir (outputs, .enc) — not the script dir when gen.sh is bundled under /app/bundled-gen.
function getGenCwd() {
  if (!config || !config.gen) return null;
  const g = config.gen;
  const base = g.baseDir ? path.resolve(g.baseDir) : null;
  if (base) {
    try {
      if (fs.existsSync(base)) return base;
    } catch (_) { /* ignore */ }
  }
  if (!g.scriptPath) return null;
  const p = path.resolve(g.scriptPath);
  let dir = path.dirname(p);
  try {
    if (fs.existsSync(p)) return path.dirname(fs.realpathSync(p));
  } catch (_) {}
  return dir;
}

// GET /api/download/:filename — serve generated .enc file (path traversal safe)
// gen.sh creates the file in its cwd; we look in the same dir we use for runGenStream first
app.get('/api/download/:filename', (req, res) => {
  try {
    if (!config) loadConfig();
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message });
  }
  const raw = req.params.filename;
  const filename = path.basename(raw);
  if (!filename || filename !== raw || filename.includes('..')) {
    return res.status(400).json({ ok: false, error: 'Invalid filename' });
  }
  const genCwd = getGenCwd();
  const scriptDir = path.resolve(path.dirname(config.gen?.scriptPath || ''));
  const baseDir = path.resolve(config.gen?.baseDir || scriptDir || '.');
  const downloadDir = config.gen?.downloadDir ? path.resolve(config.gen.downloadDir) : null;
  const candidates = [];
  if (lastPackDir && path.isAbsolute(lastPackDir)) candidates.push(lastPackDir);
  if (genCwd && !candidates.includes(genCwd)) candidates.push(genCwd);
  if (downloadDir && !candidates.includes(downloadDir)) candidates.push(downloadDir);
  if (scriptDir && !candidates.includes(scriptDir)) candidates.push(scriptDir);
  if (baseDir && !candidates.includes(baseDir)) candidates.push(baseDir);
  if (candidates.length === 0) candidates.push(path.resolve('.'));
  let fullPath = null;
  for (const dir of candidates) {
    const fp = path.resolve(dir, filename);
    if (fp.startsWith(dir + path.sep) || fp === dir) {
      if (fs.existsSync(fp) && fs.statSync(fp).isFile()) {
        fullPath = fp;
        break;
      }
    }
  }
  if (!fullPath) {
    const tried = candidates.map((d) => path.join(d, filename));
    console.error('[download]', filename, 'not found. Tried:', tried.join(', '));
    return res.status(404).json({ ok: false, error: 'File not found' });
  }
  res.setHeader('Content-Disposition', `attachment; filename="${filename.replace(/"/g, '\\"')}"`);
  res.setHeader('Content-Type', 'application/octet-stream');
  res.setHeader('Cache-Control', 'no-store');
  res.sendFile(fullPath, { maxAge: 0 }, (err) => {
    if (err && !res.headersSent) res.status(500).json({ ok: false, error: err.message });
  });
});

// GET /api/download-check?filename=xxx — debug: ดูว่า server ไปหาไฟล์ที่ path ไหนบ้าง และมีไฟล์อยู่หรือไม่
app.get('/api/download-check', (req, res) => {
  try {
    if (!config) loadConfig();
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message });
  }
  const raw = (req.query.filename || '').trim();
  const filename = path.basename(raw);
  if (!filename || filename !== raw || filename.includes('..')) {
    return res.status(400).json({ ok: false, error: 'Invalid or missing filename' });
  }
  const genCwd = getGenCwd();
  const scriptDir = path.resolve(path.dirname(config.gen?.scriptPath || ''));
  const baseDir = path.resolve(config.gen?.baseDir || scriptDir || '.');
  const downloadDir = config.gen?.downloadDir ? path.resolve(config.gen.downloadDir) : null;
  const candidates = [];
  if (lastPackDir && path.isAbsolute(lastPackDir)) candidates.push(lastPackDir);
  if (genCwd && !candidates.includes(genCwd)) candidates.push(genCwd);
  if (downloadDir && !candidates.includes(downloadDir)) candidates.push(downloadDir);
  if (scriptDir && !candidates.includes(scriptDir)) candidates.push(scriptDir);
  if (baseDir && !candidates.includes(baseDir)) candidates.push(baseDir);
  const nodeCwd = path.resolve(process.cwd());
  if (nodeCwd && !candidates.includes(nodeCwd)) candidates.push(nodeCwd);
  if (candidates.length === 0) candidates.push(path.resolve('.'));
  const checked = [];
  let foundAt = null;
  for (const dir of candidates) {
    const fullPath = path.resolve(dir, filename);
    const exists = (fullPath.startsWith(dir + path.sep) || fullPath === dir) && fs.existsSync(fullPath) && fs.statSync(fullPath).isFile();
    checked.push({ dir, fullPath, exists });
    if (exists && !foundAt) foundAt = fullPath;
  }
  const hint = !foundAt && !lastPackDir
    ? 'ถ้า lastPackDir เป็น (none): สคริปต์บน server ยังไม่ส่ง GEN_PACK_DIR — ให้อัปเดต gen.sh ให้มีบรรทัด echo GEN_PACK_DIR=$(pwd) ก่อน GEN_PACK_FILE แล้ว restart server. หรือบนเครื่องที่รัน: ls -la /opt/kafka-usermgmt/user_output/*.enc เพื่อดูว่าไฟล์อยู่ที่ไหน'
    : null;
  return res.json({
    ok: true,
    filename,
    lastPackDir: lastPackDir || null,
    candidates: checked,
    foundAt,
    message: foundAt ? 'ไฟล์เจอที่: ' + foundAt : 'ไม่เจอไฟล์ใน path ใดที่ลอง (ดู candidates ด้านบน)',
    hint: hint || undefined,
  });
});

// Last directory where add-user wrote the .enc file (from GEN_PACK_DIR); used by download so path matches.
let lastPackDir = null;

// Parse gen.sh stdout for GEN_PACK_DIR=, GEN_PACK_FILE=, GEN_PACK_NAME=, GEN_VALIDATE_PASSED= (one per line)
function parsePackFromStdout(stdout) {
  let packFile = '';
  let packName = '';
  let packDir = '';
  let verificationPassed = null;
  const lines = (stdout || '').split('\n');
  for (const line of lines) {
    const d = line.match(/^GEN_PACK_DIR=(.+)$/);
    if (d) packDir = d[1].trim();
    const m = line.match(/^GEN_PACK_FILE=(.+)$/);
    if (m) packFile = m[1].trim();
    const n = line.match(/^GEN_PACK_NAME=(.+)$/);
    if (n) packName = n[1].trim();
    const v = line.match(/^GEN_VALIDATE_PASSED=(true|false)$/);
    if (v) verificationPassed = v[1] === 'true';
  }
  if (!packName && packFile) packName = packFile.replace(/\.enc$/, '');
  if (packDir) lastPackDir = path.resolve(packDir);
  return { packFile, packName, verificationPassed };
}

// Decrypt/unpack instructions (same text as gen.sh)
function buildDecryptInstructions(packFile, packName) {
  const f = packFile || '<your_file>.enc';
  const p = packName || 'pack';
  return [
    '1) Decrypt (enter passphrase when prompted):',
    `   openssl enc -d -aes-256-cbc -salt -pbkdf2 -in ${f} -out ${p}.tar.gz`,
    '2) Unpack the folder:',
    `   tar xzf ${p}.tar.gz && cd ${p}`,
    '   Inside: credentials.txt, client.properties, certs/, README.txt',
  ];
}

// Returns absolute path if pack file exists in any candidate dir, else null (so we can fail add-user when file missing)
function resolvePackFilePath(packFile) {
  if (!packFile || !config) return null;
  const filename = path.basename(packFile);
  if (filename !== packFile || filename.includes('..')) return null;
  const scriptDir = path.resolve(path.dirname(config.gen?.scriptPath || ''));
  const baseDir = path.resolve(config.gen?.baseDir || scriptDir || '.');
  const downloadDir = config.gen?.downloadDir ? path.resolve(config.gen.downloadDir) : null;
  const candidates = [];
  if (lastPackDir && path.isAbsolute(lastPackDir)) candidates.push(lastPackDir);
  if (downloadDir && !candidates.includes(downloadDir)) candidates.push(downloadDir);
  if (scriptDir && !candidates.includes(scriptDir)) candidates.push(scriptDir);
  const userOutputScript = path.join(scriptDir, 'user_output');
  if (userOutputScript && !candidates.includes(userOutputScript)) candidates.push(userOutputScript);
  if (baseDir && !candidates.includes(baseDir)) candidates.push(baseDir);
  const userOutputBase = path.join(baseDir, 'user_output');
  if (userOutputBase && !candidates.includes(userOutputBase)) candidates.push(userOutputBase);
  if (candidates.length === 0) candidates.push(path.resolve('.'));
  for (const dir of candidates) {
    const fp = path.resolve(dir, filename);
    if ((fp.startsWith(dir + path.sep) || fp === dir) && fs.existsSync(fp) && fs.statSync(fp).isFile()) return fp;
  }
  return null;
}

function buildAddUserPayload(stdout) {
  const { packFile, packName, verificationPassed } = parsePackFromStdout(stdout);
  const exists = packFile ? resolvePackFilePath(packFile) : null;
  const ok = !!exists;
  return {
    ok,
    message: ok
      ? 'Add user completed. Download the .enc file and use the instructions below to decrypt.'
      : 'Add user completed but the .enc file was not created (e.g. volume read-only). Check server: ROOT mount must be read-write, not :ro.',
    packFile: packFile || null,
    packName: packName || null,
    downloadPath: packFile && ok ? `/api/download/${encodeURIComponent(packFile)}` : null,
    decryptInstructions: buildDecryptInstructions(packFile, packName),
    verificationPassed: verificationPassed === true,
    verificationMessage: verificationPassed === true
      ? 'User verified (auth test passed).'
      : verificationPassed === false
        ? 'User created but auth test did not pass (e.g. broker reload delay). You can test again under "Test existing user".'
        : null,
    packFileMissing: !ok && !!packFile,
  };
}

// POST /api/add-user — optional streaming: Accept: application/x-ndjson or ?stream=1
app.post('/api/add-user', (req, res) => {
  try {
    validateGenReady();
  } catch (e) {
    return apiError(res, 'add-user', e, { status: 500 });
  }
  const { systemName, topic, username, acl, aclGroupExtra, passphrase, confirmPassphrase } = req.body || {};
  const errors = [];
  const e1 = validateSafeName(systemName, 'systemName', MAX_SYSTEM_NAME_LEN);
  if (e1) errors.push(e1);
  const e2 = validateSafeName(topic, 'topic', MAX_TOPIC_LEN);
  if (e2) errors.push(e2);
  const e3 = validateSafeName(username, 'username', MAX_USERNAME_LEN);
  if (e3) errors.push(e3);
  if (!passphrase || typeof passphrase !== 'string') errors.push('passphrase required');
  if (passphrase && passphrase.length > 1024) errors.push('passphrase must be at most 1024 characters');
  if (!confirmPassphrase || typeof confirmPassphrase !== 'string') errors.push('confirmPassphrase required');
  if (passphrase && confirmPassphrase && passphrase !== confirmPassphrase) errors.push('passphrase and confirmPassphrase do not match');
  const allowedGroupOps = ['Describe', 'Delete'];
  const extraList = Array.isArray(aclGroupExtra) ? aclGroupExtra.filter((o) => allowedGroupOps.includes(String(o))) : [];
  if (aclGroupExtra != null && !Array.isArray(aclGroupExtra)) errors.push('aclGroupExtra must be an array');
  if (errors.length) return res.status(400).json({ ok: false, errors });

  const env = {
    GEN_NONINTERACTIVE: '1',
    GEN_MODE: '1',
    GEN_SYSTEM_NAME: String(systemName).trim(),
    GEN_TOPIC_NAME: String(topic).trim(),
    GEN_KAFKA_USER: String(username).trim(),
    GEN_ACL: (acl === 'read' || acl === '1') ? '1' : (acl === 'client') ? '2' : '3',
    GEN_PASSPHRASE: String(passphrase),
    GEN_VALIDATE_CONSUME: '1', // run Auth + Consume test so user sees consume works
  };
  if (extraList.length) env.GEN_ACL_GROUP_EXTRA = extraList.join(',');

  const wantStream = req.query.stream === '1' || (req.headers.accept || '').includes('application/x-ndjson');
  if (wantStream) {
    res.setHeader('Content-Type', 'application/x-ndjson');
    res.setHeader('Cache-Control', 'no-store');
    let percent = 0;
    const taskAcc = createGenTaskAccumulator();
    const emitTasklog = () => {
      try {
        res.write(JSON.stringify({ type: 'tasklog', tasks: taskAcc.snapshot() }) + '\n');
      } catch (_) {}
    };
    const writeProgress = (step) => {
      if (percent < 90) percent = Math.min(90, percent + 10);
      try { res.write(JSON.stringify({ type: 'progress', step, percent }) + '\n'); } catch (_) {}
    };
    runGenStream(env, (line) => {
      taskAcc.onStdoutLine(line);
      emitTasklog();
      const step = parseProgressLine(line);
      if (step) writeProgress(step);
    }, req, (errLine) => {
      taskAcc.onStderrLine(errLine);
      emitTasklog();
    })
      .then(({ code, stdout, stderr }) => {
        if (res.writableEnded || !res.writable) return;
        const tasks = taskAcc.finalize(code, stderr);
        try { res.write(JSON.stringify({ type: 'tasklog', tasks }) + '\n'); } catch (_) {}
        if (code !== 0) {
          res.write(JSON.stringify({
            type: 'result',
            ok: false,
            error: `gen.sh exited ${code}`,
            step: 'add-user',
            phase: 'gen',
            exitCode: code,
            stderr: stripAnsi((stderr || '').slice(-2000)),
            stdout: stripAnsi((stdout || '').slice(-1500)),
            tasks,
          }) + '\n');
        } else {
          const payload = buildAddUserPayload(stdout);
          if (payload.ok && payload.packFile) {
            appendDownloadHistory(req, payload.packFile, payload.packName);
            appendAuditLog(req, 'add-user', { username: String(username || '').trim(), systemName: String(systemName || '').trim(), topic: String(topic || '').trim() });
          }
          res.write(JSON.stringify({ type: 'result', ...payload }) + '\n');
        }
        res.end();
      })
      .catch((err) => {
        try {
          if (!res.headersSent) res.setHeader('Content-Type', 'application/x-ndjson');
          res.write(JSON.stringify({ type: 'result', ok: false, error: err.message }) + '\n');
        } catch (_) {}
        try { res.end(); } catch (_) {}
      });
    return;
  }

  runGen(env, req)
    .then(({ code, stdout, stderr }) => {
      if (code !== 0) {
        const tasks = buildTaskAccumulatorFromOutput(stdout).finalize(code, stderr);
        apiError(res, 'add-user', new Error(`gen.sh exited ${code}`), {
          status: 500, step: 'add-user', phase: 'gen', code, stderr, stdout, tasks,
        });
        return;
      }
      const payload = buildAddUserPayload(stdout);
      if (payload.packFileMissing) {
        return res.status(500).json({ ok: false, error: payload.message, packFileMissing: true, packFile: payload.packFile });
      }
      if (payload.ok && payload.packFile) {
        appendDownloadHistory(req, payload.packFile, payload.packName);
        appendAuditLog(req, 'add-user', { username: String(username || '').trim(), systemName: String(systemName || '').trim(), topic: String(topic || '').trim() });
      }
      res.json(payload);
    })
    .catch((err) => apiError(res, 'add-user', err, { status: 500, step: 'add-user' }));
});

// POST /api/test-user
app.post('/api/test-user', (req, res) => {
  try {
    validateGenReady();
  } catch (e) {
    return apiError(res, 'test-user', e, { status: 500 });
  }
  const { username, password, topic } = req.body || {};
  if (!username?.trim() || !password) return res.status(400).json({ ok: false, errors: ['username and password required'] });
  if (!topic?.trim()) return res.status(400).json({ ok: false, errors: ['topic required'] });
  const ve = validateSafeName(username, 'username', MAX_USERNAME_LEN) || validateSafeName(topic, 'topic', MAX_TOPIC_LEN);
  if (ve) return res.status(400).json({ ok: false, errors: [ve] });

  runGen({
    GEN_NONINTERACTIVE: '1',
    GEN_MODE: '2',
    GEN_KAFKA_USER: String(username).trim(),
    GEN_TEST_PASS: String(password),
    GEN_TOPIC_NAME: String(topic).trim(),
  }, req)
    .then(({ code, stdout, stderr }) => {
      if (code === 0) {
        appendAuditLog(req, 'test-user', { username: String(username || '').trim(), topic: String(topic || '').trim() });
        return res.json({ ok: true, message: 'Test completed.', output: stdout.slice(-2000) });
      }
      apiError(res, 'test-user', new Error(`gen.sh exited ${code}`), {
        status: 500, step: 'test-user', phase: 'gen', code, stderr, stdout,
      });
    })
    .catch((err) => apiError(res, 'test-user', err, { status: 500, step: 'test-user' }));
});

// POST /api/remove-user (critical: validate before run; gen.sh does full validate + rollback)
// With ?stream=1 or Accept: application/x-ndjson: progress per user (รายคน), then final result
app.post('/api/remove-user', (req, res) => {
  try {
    validateGenReady();
  } catch (e) {
    return apiError(res, 'remove-user', e, { status: 500 });
  }
  const { users } = req.body || {};
  let list = Array.isArray(users) ? users : (typeof users === 'string' ? users.split(',').map((u) => u.trim()).filter(Boolean) : []);
  if (list.length === 0) return res.status(400).json({ ok: false, errors: ['users required (array or comma-separated)'] });
  if (list.length > MAX_REMOVE_USERS) return res.status(400).json({ ok: false, errors: [`at most ${MAX_REMOVE_USERS} users per request`] });
  for (const u of list) {
    const ve = validateSafeName(u, 'each user', MAX_USERNAME_LEN);
    if (ve) return res.status(400).json({ ok: false, errors: [ve + ' (in list): ' + u] });
  }

  const wantStream = req.query.stream === '1' || (req.headers.accept || '').includes('application/x-ndjson');
  if (wantStream) {
    res.setHeader('Content-Type', 'application/x-ndjson');
    res.setHeader('Cache-Control', 'no-store');
    const total = list.length;
    const results = [];
    let index = 0;
    function next() {
      if (index >= total) {
        const allOk = results.every((r) => r.ok);
        if (allOk) appendAuditLog(req, 'remove-user', { users: list });
        try {
          res.write(JSON.stringify({
            type: 'result',
            ok: allOk,
            message: allOk ? `Remove completed: ${results.length} user(s).` : 'Some user(s) failed.',
            removed: results.filter((r) => r.ok).map((r) => r.user),
            failed: results.filter((r) => !r.ok).map((r) => ({ user: r.user, error: r.error })),
          }) + '\n');
        } catch (_) {}
        res.end();
        return;
      }
      const user = list[index];
      const pct = total > 0 ? Math.round((index / total) * 100) : 0;
      try {
        res.write(JSON.stringify({ type: 'progress', step: 'remove-user', user, percent: pct, detail: `Removing ${user}...` }) + '\n');
      } catch (_) {}
      runGen({
        GEN_NONINTERACTIVE: '1',
        GEN_MODE: '3',
        GEN_ACTION: '1',
        GEN_USERS: user,
      }, req)
        .then(({ code, stdout, stderr }) => {
          const ok = code === 0;
          results.push({ user, ok, error: ok ? null : (stderr || stdout || `Exit ${code}`).trim().slice(0, 500) });
          const pct = total > 0 ? Math.round(((index + 1) / total) * 100) : 100;
          try {
            res.write(JSON.stringify({ type: 'progress', step: 'remove-user', user, percent: pct, ok, detail: ok ? `Removed ${user}` : `Failed: ${user}` }) + '\n');
          } catch (_) {}
          index += 1;
          next();
        })
        .catch((err) => {
          results.push({ user, ok: false, error: err.message });
          try {
            res.write(JSON.stringify({ type: 'progress', step: 'remove-user', user, percent: Math.round(((index + 1) / total) * 100), ok: false, detail: `Error: ${user}` }) + '\n');
          } catch (_) {}
          index += 1;
          next();
        });
    }
    next();
    return;
  }

  runGen({
    GEN_NONINTERACTIVE: '1',
    GEN_MODE: '3',
    GEN_ACTION: '1',
    GEN_USERS: list.join(','),
  }, req)
    .then(({ code, stdout, stderr }) => {
      if (code === 0) {
        appendAuditLog(req, 'remove-user', { users: list });
        return res.json({ ok: true, message: 'Remove user(s) completed.', output: stdout.slice(-2000) });
      }
      apiError(res, 'remove-user', new Error(`gen.sh exited ${code}`), {
        status: 500, step: 'remove-user', phase: 'gen', code, stderr, stdout,
      });
    })
    .catch((err) => apiError(res, 'remove-user', err, { status: 500, step: 'remove-user' }));
});

// POST /api/change-password (critical: gen.sh validates user in both secrets then patch both or rollback)
app.post('/api/change-password', (req, res) => {
  try {
    validateGenReady();
  } catch (e) {
    return apiError(res, 'change-password', e, { status: 500 });
  }
  const { username, newPassword } = req.body || {};
  if (!username?.trim() || !newPassword) return res.status(400).json({ ok: false, errors: ['username and newPassword required'] });
  const ve = validateSafeName(username, 'username', MAX_USERNAME_LEN);
  if (ve) return res.status(400).json({ ok: false, errors: [ve] });
  if (typeof newPassword === 'string' && newPassword.length > 1024) return res.status(400).json({ ok: false, errors: ['newPassword must be at most 1024 characters'] });

  runGen({
    GEN_NONINTERACTIVE: '1',
    GEN_MODE: '3',
    GEN_ACTION: '2',
    GEN_CHANGE_USER: String(username).trim(),
    GEN_NEW_PASSWORD: String(newPassword),
  }, req)
    .then(({ code, stdout, stderr }) => {
      if (code === 0) {
        appendAuditLog(req, 'change-password', { username: String(username || '').trim() });
        return res.json({ ok: true, message: 'Change password completed.', output: stdout.slice(-2000) });
      }
      apiError(res, 'change-password', new Error(`gen.sh exited ${code}`), {
        status: 500, step: 'change-password', phase: 'gen', code, stderr, stdout,
      });
    })
    .catch((err) => apiError(res, 'change-password', err, { status: 500, step: 'change-password' }));
});

// POST /api/cleanup-acl
app.post('/api/cleanup-acl', (req, res) => {
  try {
    validateGenReady();
  } catch (e) {
    return apiError(res, 'cleanup-acl', e, { status: 500 });
  }
  runGen({
    GEN_NONINTERACTIVE: '1',
    GEN_MODE: '3',
    GEN_ACTION: '3',
  }, req)
    .then(({ code, stdout, stderr }) => {
      if (code === 0) {
        appendAuditLog(req, 'cleanup-acl', null);
        return res.json({ ok: true, message: 'Cleanup orphaned ACLs completed.', output: stdout.slice(-2000) });
      }
      apiError(res, 'cleanup-acl', new Error(`gen.sh exited ${code}`), {
        status: 500, step: 'cleanup-acl', phase: 'gen', code, stderr, stdout,
      });
    })
    .catch((err) => apiError(res, 'cleanup-acl', err, { status: 500, step: 'cleanup-acl' }));
});

function createServer() {
  if (require.main !== module) return null;
  const configAbs = getConfigAbsPath();
  if (!fs.existsSync(configAbs)) {
    SETUP_MODE = true;
    config = null;
    const defaultPort = parseInt(process.env.PORT, 10) || 3443;
    console.warn(`[startup] First-time setup: CONFIG_PATH missing (${configAbs}). Open http://0.0.0.0:${defaultPort}/setup.html`);
  } else {
    try {
      loadConfig();
      SETUP_MODE = false;
    } catch (e) {
      console.error('Failed to load config:', e.message);
      process.exit(1);
    }
  }
  const port = (config && config.server && config.server.port) || parseInt(process.env.PORT, 10) || 3443;
  const httpsConfig = config?.server?.https || {};
  const useHttps = !SETUP_MODE && (process.env.USE_HTTPS === '1' || (httpsConfig.enabled && (httpsConfig.keyPath || httpsConfig.certPath || process.env.SSL_KEY_PATH || process.env.SSL_CERT_PATH)));

  if (useHttps) {
    const keyPath = httpsConfig.keyPath || process.env.SSL_KEY_PATH;
    const certPath = httpsConfig.certPath || process.env.SSL_CERT_PATH;
    if (!keyPath || !certPath || !fs.existsSync(keyPath) || !fs.existsSync(certPath)) {
      console.error('HTTPS enabled but key or cert file missing. Set server.https.keyPath and server.https.certPath in config, or SSL_KEY_PATH and SSL_CERT_PATH.');
      process.exit(1);
    }
    const server = https.createServer(
      {
        key: fs.readFileSync(keyPath),
        cert: fs.readFileSync(certPath),
      },
      app
    );
    server.listen(port, () => {
      console.log(`Confluent Kafka User Management (HTTPS) listening on port ${port} | version ${APP_VERSION}`);
      console.log(`Static: ${STATIC_DIR}`);
      console.log(`Config: ${CONFIG_PATH}`);
      setImmediate(() => {
        if (SETUP_MODE) return;
        runOcLoginIfConfigured()
          .then(() => ensureOcSessions())
          .catch((err) => console.error('[oc-auto-login]', err.message));
        startOcSessionRefreshInterval();
      });
    });
    return server;
  }

  app.listen(port, () => {
    console.log(`Confluent Kafka User Management listening on port ${port} | version ${APP_VERSION}`);
    console.log(`Static: ${STATIC_DIR}`);
    console.log(`Config: ${CONFIG_PATH}`);
    setImmediate(() => {
      if (SETUP_MODE) return;
      runOcLoginIfConfigured()
        .then(() => ensureOcSessions())
        .catch((err) => console.error('[oc-auto-login]', err.message));
      startOcSessionRefreshInterval();
    });
  });
  return app;
}

if (require.main === module) {
  createServer();
}

module.exports = { app, loadConfig, runGen, parsePackFromStdout, buildDecryptInstructions, createServer };
