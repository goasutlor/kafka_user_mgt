'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { collectOcContextNamespacePairs } = require('../server/lib/setup-validate');

describe('collectOcContextNamespacePairs', () => {
  it('uses environments only when enabled with sites (mirror fallbackSites must not double-count)', () => {
    const master = {
      fallbackSites: [
        { ocContext: 'cwdc-dev', namespace: 'esb-dev-cwdc' },
        { ocContext: 'cwdc-sit', namespace: 'esb-sit-cwdc' },
      ],
      environments: {
        enabled: true,
        environments: [
          { id: 'dev', sites: [{ ocContext: 'cwdc-dev', namespace: 'esb-dev-cwdc' }] },
          { id: 'sit', sites: [{ ocContext: 'cwdc-sit', namespace: 'esb-sit-cwdc' }] },
        ],
      },
    };
    const pairs = collectOcContextNamespacePairs(master);
    assert.strictEqual(pairs.length, 2);
    assert.strictEqual(new Set(pairs).size, 2);
  });

  it('uses fallbackSites when environments are disabled', () => {
    const master = {
      fallbackSites: [{ ocContext: 'x', namespace: 'ns1' }],
      environments: { enabled: false },
    };
    assert.deepStrictEqual(collectOcContextNamespacePairs(master), ['x\nns1']);
  });

  it('detects duplicate (context,namespace) within environments', () => {
    const master = {
      environments: {
        enabled: true,
        environments: [
          {
            id: 'a',
            sites: [
              { ocContext: 'c', namespace: 'n' },
              { ocContext: 'c', namespace: 'n' },
            ],
          },
        ],
      },
    };
    const pairs = collectOcContextNamespacePairs(master);
    assert.strictEqual(pairs.length, 2);
    assert.strictEqual(new Set(pairs).size, 1);
  });
});
