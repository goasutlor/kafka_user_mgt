'use strict';

const crypto = require('crypto');

const ALGO = 'aes-256-gcm';
const IV_LEN = 12;
const AUTH_TAG_LEN = 16;
const KEY_LEN = 32;

function getKey(keyEnv) {
  if (!keyEnv || typeof keyEnv !== 'string') return null;
  const s = keyEnv.trim();
  if (s.length === 64 && /^[0-9a-fA-F]+$/.test(s)) return Buffer.from(s, 'hex');
  try {
    const b = Buffer.from(s, 'base64');
    return b.length === KEY_LEN ? b : null;
  } catch (_) { return null; }
}

function encrypt(plaintext, keyEnv) {
  const key = getKey(keyEnv);
  if (!key) return null;
  const iv = crypto.randomBytes(IV_LEN);
  const cipher = crypto.createCipheriv(ALGO, key, iv, { authTagLength: AUTH_TAG_LEN });
  const enc = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return 'enc:' + Buffer.concat([iv, enc, tag]).toString('base64');
}

function decrypt(encValue, keyEnv) {
  if (!encValue || typeof encValue !== 'string' || !encValue.startsWith('enc:')) return null;
  const key = getKey(keyEnv);
  if (!key) return null;
  let buf;
  try {
    buf = Buffer.from(encValue.slice(4), 'base64');
  } catch (_) { return null; }
  if (buf.length < IV_LEN + AUTH_TAG_LEN) return null;
  const iv = buf.subarray(0, IV_LEN);
  const tag = buf.subarray(buf.length - AUTH_TAG_LEN);
  const ciphertext = buf.subarray(IV_LEN, buf.length - AUTH_TAG_LEN);
  const decipher = crypto.createDecipheriv(ALGO, key, iv, { authTagLength: AUTH_TAG_LEN });
  decipher.setAuthTag(tag);
  try {
    return decipher.update(ciphertext) + decipher.final('utf8');
  } catch (_) { return null; }
}

module.exports = { encrypt, decrypt, getKey };
