#!/usr/bin/env node
'use strict';
/**
 * Manage web-login users (CLI only). Credentials are stored in a file on the server, not in config.
 * Usage:
 *   node auth-users-cli.js add <username>     # prompts for password (or set AUTH_NEW_PASSWORD)
 *   node auth-users-cli.js list
 *   node auth-users-cli.js remove <username>
 * Run from webapp/ or set CONFIG_PATH / AUTH_USERS_FILE.
 */
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { hashPassword } = require('../server/lib/auth-hash');

const CONFIG_PATH = process.env.CONFIG_PATH || path.join(__dirname, '..', 'config', 'web.config.json');
const configDir = path.dirname(path.isAbsolute(CONFIG_PATH) ? CONFIG_PATH : path.resolve(process.cwd(), CONFIG_PATH));
const AUTH_USERS_FILE = process.env.AUTH_USERS_FILE || path.join(configDir, 'auth-users.json');

function getUsersFilePath() {
  try {
    const cfgPath = path.isAbsolute(CONFIG_PATH) ? CONFIG_PATH : path.resolve(process.cwd(), CONFIG_PATH);
    if (fs.existsSync(cfgPath)) {
      const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
      const f = cfg?.server?.auth?.usersFile;
      if (f) return path.isAbsolute(f) ? f : path.resolve(path.dirname(cfgPath), f);
    }
  } catch (_) {}
  return path.isAbsolute(AUTH_USERS_FILE) ? AUTH_USERS_FILE : path.resolve(process.cwd(), AUTH_USERS_FILE);
}

function readUsers(filePath) {
  if (!fs.existsSync(filePath)) return {};
  try {
    const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    return (data && data.users && typeof data.users === 'object') ? data.users : {};
  } catch (e) {
    console.error('Error reading file:', e.message);
    process.exit(1);
  }
}

function writeUsers(filePath, users) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify({ users }, null, 2) + '\n', 'utf8');
}

function promptPassword() {
  return new Promise((resolve) => {
    if (process.env.AUTH_NEW_PASSWORD) {
      resolve(process.env.AUTH_NEW_PASSWORD);
      return;
    }
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question('Password: ', (pass) => {
      rl.close();
      resolve(pass || '');
    });
  });
}

const cmd = process.argv[2];
const arg = process.argv[3];

if (!cmd || !['add', 'list', 'remove'].includes(cmd)) {
  console.log('Usage: node auth-users-cli.js add <username> | list | remove <username>');
  process.exit(1);
}

const filePath = getUsersFilePath();

if (cmd === 'list') {
  const users = readUsers(filePath);
  const names = Object.keys(users).sort();
  if (names.length === 0) {
    console.log('No users. Add with: node auth-users-cli.js add <username>');
  } else {
    console.log('Users:', names.join(', '));
  }
  process.exit(0);
}

if (cmd === 'remove') {
  if (!arg || !arg.trim()) {
    console.error('Usage: node auth-users-cli.js remove <username>');
    process.exit(1);
  }
  const username = arg.trim();
  const users = readUsers(filePath);
  if (!users[username]) {
    console.error('User not found:', username);
    process.exit(1);
  }
  delete users[username];
  writeUsers(filePath, users);
  console.log('Removed user:', username);
  process.exit(0);
}

if (cmd === 'add') {
  if (!arg || !arg.trim()) {
    console.error('Usage: node auth-users-cli.js add <username>');
    process.exit(1);
  }
  const username = arg.trim();
  promptPassword().then((password) => {
    if (!password) {
      console.error('Password cannot be empty.');
      process.exit(1);
    }
    const users = readUsers(filePath);
    users[username] = hashPassword(password);
    writeUsers(filePath, users);
    console.log('Added user:', username);
    console.log('File:', filePath);
    process.exit(0);
  });
}
