'use strict';

const fs = require('fs');
const path = require('path');
const { verifyPassword, isHashedStored } = require('./auth-hash');
const { isMasterConfig } = require('./master-config');

const RESET_CONFIRM_PHRASE = 'RESET_PORTAL_CONFIG';

function ensureUnderConfigDir(absFile, configDir) {
  const f = path.resolve(absFile);
  const d = path.resolve(configDir);
  if (f === d) return f;
  if (!f.startsWith(d + path.sep)) {
    throw new Error(`Refusing to touch path outside config directory: ${f}`);
  }
  return f;
}

/**
 * @param {string} configAbs - CONFIG_PATH (master.config.json or legacy web.config.json)
 * @returns {{ paths: string[], skippedCredentialOutsideConfigDir: boolean }}
 */
function collectWipePaths(configAbs) {
  const configDir = path.dirname(path.resolve(configAbs));
  const masterAbs = path.resolve(configAbs);
  const paths = new Set();
  paths.add(masterAbs);

  const auditLog = path.join(configDir, 'audit.log');
  const downloadHist = path.join(configDir, 'download-history.json');
  const authUsers = path.join(configDir, 'auth-users.json');
  paths.add(auditLog);
  paths.add(downloadHist);
  paths.add(authUsers);

  let skippedCredentialOutsideConfigDir = false;
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(masterAbs, 'utf8'));
  } catch (_) {
    return { paths: [...paths], skippedCredentialOutsideConfigDir };
  }

  if (!isMasterConfig(raw)) {
    return { paths: [...paths], skippedCredentialOutsideConfigDir };
  }

  const masterDir = path.dirname(masterAbs);
  const credName = (raw.portal && raw.portal.auth && raw.portal.auth.credentialsFile) || 'credentials.json';
  const credPath = path.isAbsolute(credName) ? path.normalize(credName) : path.resolve(masterDir, credName);
  try {
    paths.add(ensureUnderConfigDir(credPath, configDir));
  } catch (_) {
    skippedCredentialOutsideConfigDir = true;
  }

  const rt = String(raw.runtimeRoot || '').trim();
  if (rt && path.isAbsolute(rt)) {
    paths.add(path.join(path.normalize(rt), 'environments.json'));
  }

  return { paths: [...paths], skippedCredentialOutsideConfigDir };
}

function verifyPortalCredentialsForWipe(configAbs, username, password) {
  const raw = JSON.parse(fs.readFileSync(configAbs, 'utf8'));
  if (!isMasterConfig(raw)) {
    throw new Error('Password-gated reset supports master.config.json only. For legacy web.config.json, delete files on the host or migrate to master format first.');
  }
  const auth = raw.portal && raw.portal.auth;
  if (!auth || auth.enabled !== true) {
    throw new Error('Portal authentication is not enabled in master.config.json. Enable portal auth first, or delete deploy/config files on the host manually (see UPGRADE-AND-PERSISTENCE.md).');
  }
  const masterDir = path.dirname(path.resolve(configAbs));
  const credName = auth.credentialsFile || 'credentials.json';
  const credPath = path.isAbsolute(credName) ? path.normalize(credName) : path.resolve(masterDir, credName);
  if (!fs.existsSync(credPath)) {
    throw new Error(`Credentials file not found: ${credPath}`);
  }
  let cred;
  try {
    cred = JSON.parse(fs.readFileSync(credPath, 'utf8'));
  } catch (e) {
    throw new Error(`Could not read credentials: ${e.message}`);
  }
  const users = cred && cred.users && typeof cred.users === 'object' ? cred.users : {};
  const u = String(username || '').trim();
  if (!u || typeof password !== 'string') {
    throw new Error('username and password are required');
  }
  const stored = users[u];
  if (stored == null) {
    throw new Error('Invalid username or password');
  }
  const ok = isHashedStored(stored) ? verifyPassword(password, stored) : stored === password;
  if (!ok) {
    throw new Error('Invalid username or password');
  }
  return { ok: true, user: u };
}

/**
 * Unlink each path if it exists. Ignores missing files.
 * @param {string[]} paths
 * @returns {{ removed: string[], errors: string[] }}
 */
function performWipe(paths) {
  const removed = [];
  const errors = [];
  for (const p of paths) {
    if (!p || typeof p !== 'string') continue;
    try {
      if (fs.existsSync(p)) {
        fs.unlinkSync(p);
        removed.push(p);
      }
    } catch (e) {
      errors.push(`${p}: ${e.message}`);
    }
  }
  return { removed, errors };
}

module.exports = {
  RESET_CONFIRM_PHRASE,
  collectWipePaths,
  verifyPortalCredentialsForWipe,
  performWipe,
};
