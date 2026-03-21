#!/usr/bin/env node
'use strict';
/**
 * Encrypt OC login password for use in web.config.json (gen.ocLoginPassword).
 * Usage:
 *   export OC_CREDENTIALS_KEY="64-char-hex-or-32-byte-base64"
 *   node encrypt-oc-password.js "ocp@dmin!"
 * Output: enc:xxxx — put this in gen.ocLoginPassword. Keep OC_CREDENTIALS_KEY in env when running the server.
 */
const { encrypt, getKey } = require('../server/lib/oc-encrypt');

const keyEnv = process.env.OC_CREDENTIALS_KEY;
const password = process.argv[2];

if (!password) {
  console.error('Usage: OC_CREDENTIALS_KEY=<key> node encrypt-oc-password.js "<password>"');
  process.exit(1);
}

if (!getKey(keyEnv)) {
  console.error('OC_CREDENTIALS_KEY must be 32 bytes: 64 hex chars or 44 base64 chars. Example: openssl rand -hex 32');
  process.exit(1);
}

const out = encrypt(password, keyEnv);
if (!out) {
  console.error('Encryption failed.');
  process.exit(1);
}
console.log(out);
