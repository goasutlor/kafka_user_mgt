'use strict';

/**
 * Detect Dev / SIT / UAT / PROD from namespace, label, or id (OpenShift/Kafka naming).
 */
function detectEnvTier(text) {
  const lower = String(text || '').toLowerCase();
  if (/\b(prod|production)\b/.test(lower)) return 'PROD';
  if (/\b(uat|stg|staging)\b/.test(lower)) return 'UAT';
  if (/\bsit\b/.test(lower)) return 'SIT';
  if (/\b(dev|development)\b/.test(lower)) return 'DEV';
  return null;
}

const MAX_BADGE = 14;

/**
 * Short header badge: prefer DEV/SIT/UAT/PROD when present in namespace/label/id;
 * otherwise use a readable slice (not 4 chars — avoids misleading short prefixes).
 */
function shortEnvBadge(namespace, label, id) {
  const ns = String(namespace || '').trim();
  const lab = String(label || '').trim();
  const eid = String(id || '').trim();
  const tier = detectEnvTier(ns) || detectEnvTier(lab) || detectEnvTier(eid);
  if (tier) return tier;
  if (ns.length) {
    const u = ns.toUpperCase();
    return u.length <= MAX_BADGE ? u : u.slice(0, MAX_BADGE);
  }
  if (lab.length) {
    const u = lab.toUpperCase();
    return u.length <= MAX_BADGE ? u : u.slice(0, MAX_BADGE);
  }
  if (eid.length) {
    const u = eid.toUpperCase();
    return u.length <= MAX_BADGE ? u : u.slice(0, MAX_BADGE);
  }
  return 'ENV';
}

module.exports = { detectEnvTier, shortEnvBadge };
