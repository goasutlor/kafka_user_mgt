'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { expandMasterToLegacy } = require('./master-config');
const { buildFilesFromSetupBody } = require('./setup-writer');

/** Collect every ocContext from fallbackSites and from multi-environment definitions. */
function collectOcContexts(master) {
  const out = new Set();
  if (Array.isArray(master.fallbackSites)) {
    for (const s of master.fallbackSites) {
      if (s && s.ocContext) out.add(String(s.ocContext).trim());
    }
  }
  const env = master.environments;
  if (env && env.enabled === true && Array.isArray(env.environments)) {
    for (const e of env.environments) {
      if (!e || e.enabled === false) continue;
      if (Array.isArray(e.sites)) {
        for (const s of e.sites) {
          if (s && s.ocContext) out.add(String(s.ocContext).trim());
        }
      } else if (e.ocContext && e.namespace) {
        out.add(String(e.ocContext).trim());
      }
    }
  }
  return [...out].filter(Boolean);
}

function redactSecrets(obj) {
  if (!obj || typeof obj !== 'object') return obj;
  if (Array.isArray(obj)) return obj.map(redactSecrets);
  const out = {};
  for (const k of Object.keys(obj)) {
    const v = obj[k];
    const lk = k.toLowerCase();
    if (lk.includes('password') || lk === 'token' || lk.includes('secret')) {
      out[k] = v ? '***' : v;
    } else if (typeof v === 'object' && v !== null) {
      out[k] = redactSecrets(v);
    } else {
      out[k] = v;
    }
  }
  return out;
}

function mergeOcFromCredentialsIntoGen(gen, ocBlock) {
  if (!ocBlock || typeof ocBlock !== 'object') return;
  if (ocBlock.loginUser) gen.ocLoginUser = ocBlock.loginUser;
  if (ocBlock.loginPassword) gen.ocLoginPassword = ocBlock.loginPassword;
  if (ocBlock.loginServers && typeof ocBlock.loginServers === 'object') {
    gen.ocLoginServers = { ...(gen.ocLoginServers || {}), ...ocBlock.loginServers };
  }
  if (ocBlock.loginTokens && typeof ocBlock.loginTokens === 'object') {
    gen.ocLoginTokens = { ...(gen.ocLoginTokens || {}), ...ocBlock.loginTokens };
  }
  if (ocBlock.loginCredentials && typeof ocBlock.loginCredentials === 'object') {
    gen.ocLoginCredentials = { ...(gen.ocLoginCredentials || {}), ...ocBlock.loginCredentials };
  }
  if (ocBlock.ocAutoLogin === true || ocBlock.autoLogin === true) gen.ocAutoLogin = true;
}

function looksLikeHttpsApiUrl(u) {
  if (!u || typeof u !== 'string') return false;
  return /^https:\/\/.+/i.test(u.trim());
}

/**
 * Build + validate setup body; optional filesystem / oc checks (warnings if files missing).
 * @returns {{ checks: Array<{id:string,level:string,message:string}>, summary: object, masterPreview: object, canSave: boolean }}
 */
function runSetupPreview(body, configAbsPath) {
  const built = buildFilesFromSetupBody(body, configAbsPath);
  const expanded = expandMasterToLegacy(built.master, configAbsPath);
  if (built.credentials && built.credentials.oc) {
    mergeOcFromCredentialsIntoGen(expanded.gen, built.credentials.oc);
  }

  const checks = [];
  const g = expanded.gen || {};
  const master = built.master;

  if (!String(g.bootstrapServers || '').trim()) {
    checks.push({ id: 'kafka_bootstrap', level: 'error', message: 'Kafka bootstrapServers is empty' });
  } else {
    checks.push({ id: 'kafka_bootstrap', level: 'ok', message: 'Bootstrap servers set' });
  }

  const k8sSn = String((master.kafka && master.kafka.k8sSecretName) || '').trim();
  if (!k8sSn) {
    checks.push({ id: 'k8s_secret_name', level: 'error', message: 'Kubernetes secret name for user list updates is empty' });
  } else if (k8sSn === 'kafka-server-side-credentials') {
    checks.push({
      id: 'k8s_secret_name',
      level: 'ok',
      message: 'Secret name: kafka-server-side-credentials (Confluent default for SASL/plain user data, key plain-users.json). Not the same as kafka-admin-client-credentials, kafka-client-side-credentials, or listener apikey secrets.',
    });
  } else {
    checks.push({
      id: 'k8s_secret_name',
      level: 'ok',
      message: `Custom secret "${k8sSn}" — ensure it exists in every configured namespace and is the secret your platform uses for the plain user list.`,
    });
  }

  const contexts = collectOcContexts(master);
  if (contexts.length === 0) {
    const lvl = master.oc && master.oc.autoLogin === true ? 'error' : 'warn';
    checks.push({
      id: 'oc_contexts',
      level: lvl,
      message:
        lvl === 'error'
          ? 'OC auto-login requires OCP sites (or environments with sites); no context found'
          : 'No OCP contexts from fallbackSites or environments — defaults may not match your cluster',
    });
  } else {
    const uniq = new Set(contexts);
    if (uniq.size !== contexts.length) {
      checks.push({ id: 'oc_contexts_unique', level: 'error', message: 'Duplicate ocContext values in sites / environments' });
    } else {
      checks.push({
        id: 'oc_contexts',
        level: 'ok',
        message: `OCP contexts: ${contexts.join(', ')}`,
      });
    }
  }

  const servers = master.oc && master.oc.loginServers ? master.oc.loginServers : {};
  if (master.oc && master.oc.autoLogin === true) {
    for (const ctx of contexts) {
      const url = servers[ctx];
      if (!url || !String(url).trim()) {
        checks.push({
          id: 'oc_api_' + ctx,
          level: 'error',
          message: `OC auto-login: no API URL in loginServers for context "${ctx}"`,
        });
      } else if (!looksLikeHttpsApiUrl(url)) {
        checks.push({
          id: 'oc_api_' + ctx,
          level: 'warn',
          message: `API URL for "${ctx}" should usually start with https:// (got: ${String(url).slice(0, 60)}…)`,
        });
      } else {
        checks.push({ id: 'oc_api_' + ctx, level: 'ok', message: `API URL set for context "${ctx}"` });
      }
    }
    const credMode = body.ocCredentialMode === 'per_cluster' ? 'per_cluster' : 'shared';
    if (contexts.length) {
      if (credMode === 'per_cluster') {
        const lc = (built.credentials.oc && built.credentials.oc.loginCredentials) || {};
        for (const ctx of contexts) {
          const c = lc[ctx];
          if (!c || !c.user || !c.password) {
            checks.push({
              id: 'oc_cred_' + ctx,
              level: 'error',
              message: `Per-cluster OC credentials missing for context "${ctx}"`,
            });
          } else {
            checks.push({ id: 'oc_cred_' + ctx, level: 'ok', message: `OC credentials present for "${ctx}"` });
          }
        }
      } else {
        const u = g.ocLoginUser;
        const p = g.ocLoginPassword;
        if (!u || !p) {
          checks.push({
            id: 'oc_cred_shared',
            level: 'error',
            message: 'OC auto-login (shared credentials): set ocLoginUser and ocLoginPassword',
          });
        } else {
          checks.push({ id: 'oc_cred_shared', level: 'ok', message: 'Shared OC user/password set' });
        }
      }
    }
    if (body.ocTopology === 'dual' && contexts.length >= 2) {
      const credModeDual = body.ocCredentialMode === 'per_cluster' ? 'per_cluster' : 'shared';
      if (credModeDual !== 'per_cluster') {
        checks.push({
          id: 'oc_2region_shared',
          level: 'warn',
          message: '2-region setup with shared OC login: only valid if the same account can authenticate to both API URLs; otherwise use different user/password per region.',
        });
      }
    }
  }

  const kc = g.kubeconfigPath || '';
  if (kc) {
    if (fs.existsSync(kc)) {
      checks.push({ id: 'kubeconfig_file', level: 'ok', message: `Kubeconfig found: ${kc}` });
    } else {
      checks.push({
        id: 'kubeconfig_file',
        level: 'warn',
        message: `Kubeconfig not found yet at ${kc} (mount runtime .kube or run oc login after save)`,
      });
    }
  }

  const clientPath = g.clientConfig;
  const adminPath = g.adminConfig;
  if (clientPath) {
    checks.push(
      fs.existsSync(clientPath)
        ? { id: 'kafka_client_props', level: 'ok', message: `Client properties found: ${clientPath}` }
        : {
            id: 'kafka_client_props',
            level: 'warn',
            message: `Client properties not found at ${clientPath} (copy under runtime configs after setup)`,
          }
    );
  }
  if (adminPath) {
    checks.push(
      fs.existsSync(adminPath)
        ? { id: 'kafka_admin_props', level: 'ok', message: `Admin properties found: ${adminPath}` }
        : {
            id: 'kafka_admin_props',
            level: 'warn',
            message: `Admin properties not found at ${adminPath}`,
          }
    );
  }

  const ocDir = g.ocPath || '/host/usr/bin';
  const ocExe = path.join(String(ocDir).replace(/[/\\]+$/, ''), process.platform === 'win32' ? 'oc.exe' : 'oc');
  if (fs.existsSync(ocExe)) {
    const r = spawnSync(ocExe, ['version', '--client'], { encoding: 'utf8', timeout: 8000 });
    if (r.status === 0) {
      const line = (r.stdout || '').split('\n')[0] || 'ok';
      checks.push({ id: 'oc_binary', level: 'ok', message: `oc CLI: ${line.trim().slice(0, 120)}` });
    } else {
      checks.push({
        id: 'oc_binary',
        level: 'warn',
        message: `oc exists at ${ocExe} but version check failed`,
      });
    }
  } else {
    checks.push({
      id: 'oc_binary',
      level: 'warn',
      message: `oc not found at ${ocExe} (install or mount host /usr/bin; optional if kubeconfig pre-logged-in)`,
    });
  }

  if (master.portal && master.portal.auth && master.portal.auth.enabled === true) {
    const users = built.credentials.users || {};
    if (!Object.keys(users).length) {
      checks.push({ id: 'portal_auth', level: 'error', message: 'Portal auth enabled but no admin user in credentials' });
    } else {
      checks.push({ id: 'portal_auth', level: 'ok', message: 'Portal admin user configured' });
    }
  }

  const canSave = !checks.some((c) => c.level === 'error');
  const summary = {
    confluentArchitecture: body.ocTopology === 'dual' ? '2_regions' : 'single_region',
    topology: body.ocTopology === 'dual' ? 'dual_ocp' : 'single_ocp',
    runtimeRoot: master.runtimeRoot,
    bootstrapServers: master.kafka && master.kafka.bootstrapServers,
    k8sSecretName: k8sSn,
    ocContexts: contexts,
    ocAutoLogin: !!(master.oc && master.oc.autoLogin),
    sites: master.fallbackSites || [],
    environmentsEnabled: !!(master.environments && master.environments.enabled === true),
    portalPort: master.portal && master.portal.port,
    portalAuth: !!(master.portal && master.portal.auth && master.portal.auth.enabled),
  };

  return {
    checks,
    summary,
    masterPreview: redactSecrets(built.master),
    credentialsPreview: redactSecrets(built.credentials),
    canSave,
  };
}

module.exports = {
  runSetupPreview,
  collectOcContexts,
  redactSecrets,
};
