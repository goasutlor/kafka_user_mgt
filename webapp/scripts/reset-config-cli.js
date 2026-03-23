#!/usr/bin/env node
'use strict';

/**
 * CLI parity with Web POST /api/setup/reset and /reset-config.html.
 * Wipes master.config + credentials + audit/history + runtime environments.json (same rules as server).
 *
 * Usage:
 *   CONFIG_PATH=/app/config/master.config.json node webapp/scripts/reset-config-cli.js
 *   GEN_NONINTERACTIVE=1 GEN_MODE=9 CONFIG_PATH=... ./gen.sh  (from repo; finds this script)
 */

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const {
  RESET_CONFIRM_PHRASE,
  collectWipePaths,
  verifyPortalCredentialsForWipe,
  performWipe,
} = require(path.join(__dirname, '../server/lib/setup-reset'));
const { configDirectoryWritable } = require(path.join(__dirname, '../server/lib/setup-writer'));

const configAbs = process.env.CONFIG_PATH
  ? (path.isAbsolute(process.env.CONFIG_PATH)
    ? process.env.CONFIG_PATH
    : path.resolve(process.cwd(), process.env.CONFIG_PATH))
  : path.resolve(process.cwd(), 'config', 'master.config.json');

function ask(rl, q) {
  return new Promise((resolve) => {
    rl.question(q, (a) => resolve(a));
  });
}

async function main() {
  if (!fs.existsSync(configAbs)) {
    console.error('Config not found:', configAbs);
    process.exit(1);
  }
  const dirOk = configDirectoryWritable(configAbs);
  if (!dirOk.ok) {
    console.error('Config directory not writable:', dirOk.error);
    process.exit(1);
  }

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    const user = (await ask(rl, 'Portal username: ')).trim();
    const pass = await ask(rl, 'Portal password: ');
    const phrase = (await ask(rl, `Type "${RESET_CONFIRM_PHRASE}" to confirm wipe: `)).trim();
    if (phrase !== RESET_CONFIRM_PHRASE) {
      console.error('Aborted: confirmation phrase does not match.');
      process.exit(1);
    }
    verifyPortalCredentialsForWipe(configAbs, user, pass);
    const wipe = collectWipePaths(configAbs);
    const result = performWipe(wipe.paths);
    console.log('Removed:', result.removed.join(', ') || '(none)');
    if (result.errors.length) {
      console.error('Errors:', result.errors.join('; '));
      process.exit(1);
    }
    if (wipe.skippedCredentialOutsideConfigDir) {
      console.warn('Note: credentials path was outside config dir — that file was not deleted.');
    }
    console.log('Done. Run the portal and open /setup.html for first-time setup again.');
  } catch (e) {
    console.error(e.message || e);
    process.exit(1);
  } finally {
    rl.close();
  }
}

main();
