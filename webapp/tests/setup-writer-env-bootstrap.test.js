'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { buildFilesFromSetupBody, masterToSetupWizardBody } = require('../server/lib/setup-writer');

describe('buildFilesFromSetupBody environment bootstrap overrides', () => {
  it('merges environmentBootstrapOverrides into environment entries', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ku-envbs-'));
    const configAbs = path.join(dir, 'master.config.json');
    const built = buildFilesFromSetupBody(
      {
        runtimeRoot: '/opt/kafka-usermgmt',
        kafkaBootstrap: 'kafka-global.example.com:443',
        environmentsEnabled: true,
        defaultEnvironmentId: 'dev',
        environmentItems: [
          {
            id: 'dev',
            label: 'Dev',
            shortLabel: 'DEV',
            badgeColor: '#238636',
            sites: [{ name: 'cwdc', ocContext: 'cwdc', namespace: 'esb-dev-cwdc' }],
          },
          {
            id: 'sit',
            label: 'SIT',
            shortLabel: 'SIT',
            badgeColor: '#9e6a03',
            sites: [{ name: 'cwdc', ocContext: 'cwdc', namespace: 'esb-sit-cwdc' }],
          },
        ],
        environmentBootstrapOverrides: {
          sit: 'kafka-sit.example.com:443',
        },
      },
      configAbs,
    );
    const envs = built.master.environments.environments;
    const dev = envs.find((e) => e.id === 'dev');
    const sit = envs.find((e) => e.id === 'sit');
    assert.ok(dev);
    assert.strictEqual(dev.bootstrapServers, undefined);
    assert.ok(sit);
    assert.strictEqual(sit.bootstrapServers, 'kafka-sit.example.com:443');
  });

  it('merges apiServer from multi-site environment into oc.loginServers', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ku-envapi-'));
    const configAbs = path.join(dir, 'master.config.json');
    const built = buildFilesFromSetupBody(
      {
        runtimeRoot: '/opt/kafka-usermgmt',
        kafkaBootstrap: 'kafka.example.com:443',
        environmentsEnabled: true,
        defaultEnvironmentId: 'prod',
        ocAutoLogin: true,
        ocLoginUser: 'u',
        ocLoginPassword: 'p',
        environmentItems: [
          {
            id: 'prod',
            label: 'Prod',
            shortLabel: 'PRD',
            badgeColor: '#238636',
            sites: [
              {
                name: 'site1',
                ocContext: 'ctx-site1-prod',
                namespace: 'ns-site1',
                apiServer: 'https://api.site1.example:6443',
              },
              {
                name: 'site2',
                ocContext: 'ctx-site2-prod',
                namespace: 'ns-site2',
                apiServer: 'https://api.site2.example:6443',
              },
            ],
          },
        ],
      },
      configAbs,
    );
    const ls = built.master.oc.loginServers;
    assert.strictEqual(ls['ctx-site1-prod'], 'https://api.site1.example:6443');
    assert.strictEqual(ls['ctx-site2-prod'], 'https://api.site2.example:6443');
  });

  it('infers multi-env from single-topology ocSites when environmentsEnabled was omitted (hidden checkbox off)', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ku-envinfer-'));
    const configAbs = path.join(dir, 'master.config.json');
    const built = buildFilesFromSetupBody(
      {
        runtimeRoot: '/opt/kafka-usermgmt',
        kafkaBootstrap: 'kafka-dev.example.com:443',
        ocTopology: 'single',
        ocSites: [
          { ocContext: 'cwdc-dev', namespace: 'esb-dev-cwdc', apiServer: 'https://api.example:6443' },
          { ocContext: 'cwdc-sit', namespace: 'esb-sit-cwdc', apiServer: 'https://api.example:6443' },
          { ocContext: 'cwdc-uat', namespace: 'esb-uat-cwdc', apiServer: 'https://api.example:6443' },
        ],
      },
      configAbs,
    );
    assert.strictEqual(built.master.environments.enabled, true);
    assert.strictEqual(built.master.environments.defaultEnvironmentId, 'esb-dev-cwdc');
    const ids = built.master.environments.environments.map((e) => e.id).sort();
    assert.deepStrictEqual(ids, ['esb-dev-cwdc', 'esb-sit-cwdc', 'esb-uat-cwdc'].sort());
  });

  it('does not infer multi-env for dual topology (two regions, one bootstrap)', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ku-envdual-'));
    const configAbs = path.join(dir, 'master.config.json');
    const built = buildFilesFromSetupBody(
      {
        runtimeRoot: '/opt/kafka-usermgmt',
        kafkaBootstrap: 'kafka.example.com:443',
        ocTopology: 'dual',
        ocSites: [
          { ocContext: 'ctx-a', namespace: 'ns-a', apiServer: 'https://api-a:6443' },
          { ocContext: 'ctx-b', namespace: 'ns-b', apiServer: 'https://api-b:6443' },
        ],
      },
      configAbs,
    );
    assert.strictEqual(built.master.environments.enabled, false);
  });

  it('masterToSetupWizardBody uses single topology for multiple fallbackSites when not dual-style env', () => {
    const w = masterToSetupWizardBody({
      runtimeRoot: '/opt/kafka-usermgmt',
      kafka: { bootstrapServers: 'k:443' },
      oc: { loginServers: { ctx1: 'https://api:6443', ctx2: 'https://api:6443' } },
      fallbackSites: [
        { name: 'ctx1', namespace: 'ns-dev', ocContext: 'ctx1' },
        { name: 'ctx2', namespace: 'ns-sit', ocContext: 'ctx2' },
      ],
      environments: { enabled: false },
    });
    assert.strictEqual(w.ocTopology, 'single');
  });

  it('masterToSetupWizardBody keeps dual when one env has two sites', () => {
    const w = masterToSetupWizardBody({
      runtimeRoot: '/opt/kafka-usermgmt',
      kafka: { bootstrapServers: 'k:443' },
      environments: {
        enabled: true,
        defaultEnvironmentId: 'prod',
        environments: [
          {
            id: 'prod',
            label: 'Prod',
            sites: [
              { name: 's1', ocContext: 'c1', namespace: 'n1' },
              { name: 's2', ocContext: 'c2', namespace: 'n2' },
            ],
          },
        ],
      },
    });
    assert.strictEqual(w.ocTopology, 'dual');
  });
});
