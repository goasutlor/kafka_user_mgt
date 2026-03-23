'use strict';

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');

describe('getBootstrapServersForRequest (multi-env)', () => {
  let tmpDir;
  let prevConfigPath;
  const dummyScript = path.join(__dirname, 'fixtures', 'dummy-gen.sh');

  before(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kfk-bs-'));
    const configsDir = path.join(tmpDir, 'configs');
    fs.mkdirSync(configsDir, { recursive: true });
    fs.writeFileSync(
      path.join(configsDir, 'kafka-client-master-dev.properties'),
      'bootstrap.servers=kafka-dev.apps.example:443\n',
    );
    fs.writeFileSync(
      path.join(configsDir, 'kafka-client-master-sit.properties'),
      'bootstrap.servers=kafka-sit.apps.example:443\n',
    );
    fs.writeFileSync(
      path.join(tmpDir, 'environments.json'),
      JSON.stringify({
        enabled: true,
        defaultEnvironmentId: 'dev',
        environments: [
          { id: 'dev', label: 'Dev', sites: [{ namespace: 'n1', ocContext: 'c1' }] },
          { id: 'sit', label: 'Sit', sites: [{ namespace: 'n2', ocContext: 'c2' }] },
        ],
      }),
    );
    const cfgPath = path.join(tmpDir, 'web.config.json');
    fs.writeFileSync(
      cfgPath,
      JSON.stringify({
        gen: {
          scriptPath: dummyScript,
          baseDir: tmpDir,
          kafkaBin: path.join(tmpDir, 'kafka_2.13-3.6.1', 'bin'),
          bootstrapServers: 'GLOBAL_SHOULD_NOT_WIN_FOR_MULTI_ENV:9092',
        },
        server: {
          port: 3999,
          environments: { enabled: true, file: 'environments.json' },
          auth: { enabled: false },
        },
      }),
    );
    prevConfigPath = process.env.CONFIG_PATH;
    process.env.CONFIG_PATH = cfgPath;
    delete require.cache[require.resolve('../server/index.js')];
  });

  after(() => {
    process.env.CONFIG_PATH = prevConfigPath;
    delete require.cache[require.resolve('../server/index.js')];
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch (_) {}
  });

  it('uses per-env admin properties before global gen.bootstrapServers when JSON omits bootstrapServers', () => {
    const { getBootstrapServersForRequest, loadConfig } = require('../server/index.js');
    loadConfig();
    const sitBs = getBootstrapServersForRequest({ session: { activeEnvironmentId: 'sit' } });
    assert.strictEqual(sitBs, 'kafka-sit.apps.example:443');
    const devBs = getBootstrapServersForRequest({ session: { activeEnvironmentId: 'dev' } });
    assert.strictEqual(devBs, 'kafka-dev.apps.example:443');
  });
});
