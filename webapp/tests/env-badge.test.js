'use strict';

const assert = require('node:assert');
const { describe, it } = require('node:test');
const { shortEnvBadge, detectEnvTier } = require('../server/lib/env-badge');

describe('env-badge', () => {
  it('detects UAT from esb-uat-cwdc style namespace', () => {
    assert.strictEqual(detectEnvTier('esb-uat-cwdc'), 'UAT');
    assert.strictEqual(shortEnvBadge('esb-uat-cwdc', '', ''), 'UAT');
  });
  it('detects DEV/SIT/PROD', () => {
    assert.strictEqual(shortEnvBadge('proj-dev-ns', '', ''), 'DEV');
    assert.strictEqual(shortEnvBadge('kafka-sit-01', '', ''), 'SIT');
    assert.strictEqual(shortEnvBadge('kafka-prod', '', ''), 'PROD');
  });
  it('falls back to namespace slice when no tier token', () => {
    assert.strictEqual(shortEnvBadge('my-long-namespace-name', '', ''), 'MY-LONG-NAMESP');
  });
});
