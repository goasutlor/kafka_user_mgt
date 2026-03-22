'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { buildFilesFromSetupBody } = require('../server/lib/setup-writer');

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
});
