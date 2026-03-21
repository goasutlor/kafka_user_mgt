'use strict';

const crypto = require('crypto');

const SCRYPT_N = 16384;
const SCRYPT_R = 8;
const SCRYPT_P = 1;
const KEYLEN = 32;

function hashPassword(plainPassword) {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(plainPassword, salt, KEYLEN, { N: SCRYPT_N, r: SCRYPT_R, p: SCRYPT_P });
  return salt.toString('base64') + ':' + hash.toString('base64');
}

function verifyPassword(plainPassword, stored) {
  if (!stored || typeof stored !== 'string') return false;
  const parts = stored.split(':');
  if (parts.length !== 2 || parts[0].length < 16 || parts[1].length < 32) return false;
  let salt, hash;
  try {
    salt = Buffer.from(parts[0], 'base64');
    hash = Buffer.from(parts[1], 'base64');
  } catch (_) { return false; }
  if (salt.length !== 16 || hash.length !== KEYLEN) return false;
  const derived = crypto.scryptSync(plainPassword, salt, KEYLEN, { N: SCRYPT_N, r: SCRYPT_R, p: SCRYPT_P });
  return crypto.timingSafeEqual(hash, derived);
}

function isHashedStored(stored) {
  if (!stored || typeof stored !== 'string') return false;
  const parts = stored.split(':');
  return parts.length === 2 && parts[0].length >= 16 && parts[1].length >= 32 && /^[A-Za-z0-9+/]+=*$/.test(parts[0]) && /^[A-Za-z0-9+/]+=*$/.test(parts[1]);
}

module.exports = { hashPassword, verifyPassword, isHashedStored };
