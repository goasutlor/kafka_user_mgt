'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync, spawn } = require('child_process');
const { expandMasterToLegacy } = require('./master-config');
const { buildFilesFromSetupBody } = require('./setup-writer');
const {
  validateKafkaConnectionCompleteness,
  hasFullKafkaConnection,
  materializeKafkaConnectionFiles,
  verifyTruststoreWithKeytool,
  truststoreUsesExistingFile,
} = require('./setup-kafka-files');

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

/** Every (context, namespace) pair — duplicate pair is an error; same context with different namespaces is OK. */
function collectOcContextNamespacePairs(master) {
  const pairs = [];
  const add = (ctx, ns) => {
    const c = String(ctx || '').trim();
    const n = String(ns || '').trim();
    if (c && n) pairs.push(`${c}\n${n}`);
  };
  if (Array.isArray(master.fallbackSites)) {
    for (const s of master.fallbackSites) {
      if (s) add(s.ocContext, s.namespace);
    }
  }
  const env = master.environments;
  if (env && env.enabled === true && Array.isArray(env.environments)) {
    for (const e of env.environments) {
      if (!e || e.enabled === false) continue;
      if (Array.isArray(e.sites)) {
        for (const s of e.sites) {
          if (s) add(s.ocContext, s.namespace);
        }
      } else {
        add(e.ocContext, e.namespace);
      }
    }
  }
  return pairs;
}

function redactSecrets(obj) {
  if (!obj || typeof obj !== 'object') return obj;
  if (Array.isArray(obj)) return obj.map(redactSecrets);
  const out = {};
  for (const k of Object.keys(obj)) {
    const v = obj[k];
    const lk = k.toLowerCase();
    if (
      lk.includes('password')
      || lk === 'token'
      || lk.includes('secret')
      || lk === 'kafkatruststorejksbase64'
      || lk === 'kafkatruststorepem'
      || lk === 'kafkasaslpassword'
      || lk === 'kafkaadminsaslpassword'
      || lk === 'kafkatruststorepassword'
    ) {
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

/** Resolve gen.baseDir the same way as runtime topic listing. */
function resolveGenBaseDir(g) {
  return path.resolve(g.baseDir || g.rootDir || process.cwd());
}

function resolveKafkaTopicsScriptPath(g) {
  const baseDir = resolveGenBaseDir(g);
  const kafkaBin = g.kafkaBin
    ? (path.isAbsolute(g.kafkaBin) ? g.kafkaBin : path.join(baseDir, g.kafkaBin))
    : path.join(baseDir, 'kafka_2.13-3.6.1', 'bin');
  return path.join(kafkaBin, 'kafka-topics.sh');
}

/** Run oc (or any process) with wall-clock timeout; resolves { status, stdout, stderr }. */
function spawnWithTimeout(exe, args, env, timeoutMs) {
  return new Promise((resolve) => {
    const child = spawn(exe, args, { env, windowsHide: true });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      try {
        child.kill('SIGTERM');
        setTimeout(() => {
          try { child.kill('SIGKILL'); } catch (_) {}
        }, 1500);
      } catch (_) {}
    }, timeoutMs);
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('error', (err) => {
      clearTimeout(timer);
      resolve({ status: 1, stdout, stderr: String(err.message || err) });
    });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      if (signal === 'SIGTERM' || signal === 'SIGKILL') {
        resolve({ status: 124, stdout, stderr: `${stderr}\n(timed out after ${timeoutMs}ms)`.trim() });
      } else {
        resolve({ status: code, stdout, stderr });
      }
    });
  });
}

/** Parse context NAMEs from `oc config get-contexts --no-headers` (first column or second if current marker *). */
function parseContextNamesFromGetContextsStdout(stdout) {
  const lines = (stdout || '').trim().split(/\n/).filter(Boolean);
  return lines.map((line) => {
    const parts = line.trim().split(/\s+/).filter(Boolean);
    return parts[0] === '*' ? (parts[1] || parts[0]) : (parts[0] || '');
  }).filter(Boolean);
}

/** Unix: warn if .properties is readable by group/other (credential files). */
function checkSensitiveFilePermissions(filePath, checks, idPrefix) {
  if (process.platform === 'win32' || !filePath || !fs.existsSync(filePath)) return;
  try {
    const st = fs.statSync(filePath);
    if ((st.mode & 0o077) !== 0) {
      checks.push({
        id: `${idPrefix}_file_perms`,
        level: 'warn',
        message: `${filePath} is readable by group/other — use chmod 600 on credential-related files`,
      });
    }
  } catch (_) {}
}

function checkTruststoreFromPropsFile(propsPath, checks) {
  if (!propsPath || !fs.existsSync(propsPath)) return;
  let text;
  try {
    text = fs.readFileSync(propsPath, 'utf8');
  } catch (_) {
    return;
  }
  const m = text.match(/^\s*ssl\.truststore\.location\s*=\s*(.+)\s*$/m);
  if (!m) {
    checks.push({
      id: 'ssl_truststore_in_props',
      level: 'warn',
      message: 'No ssl.truststore.location in admin properties (OK only if cluster does not use TLS truststore in this file)',
    });
    return;
  }
  let loc = m[1].trim();
  if ((loc.startsWith('"') && loc.endsWith('"')) || (loc.startsWith("'") && loc.endsWith("'"))) {
    loc = loc.slice(1, -1);
  }
  if (!fs.existsSync(loc)) {
    checks.push({
      id: 'ssl_truststore_file',
      level: 'error',
      message: `Truststore file missing at ${loc} (from admin properties) — topic list / ACL often fails until this path is valid inside the container`,
    });
  } else {
    checks.push({ id: 'ssl_truststore_file', level: 'ok', message: `Truststore file present: ${loc}` });
  }
}

/**
 * Build + validate setup body; optional filesystem / oc checks; optional live Kafka + OC checks.
 * @param {object} options
 * @param {boolean} [options.deepVerify] - run kafka-topics --list and oc whoami per context (slower; needs network/cluster access)
 * @param {boolean} [options.quickVerify] - with deepVerify: skip live Kafka + OC calls (static checks only; faster)
 * @returns {Promise<{ checks: Array<{id:string,level:string,message:string}>, summary: object, masterPreview: object, canSave: boolean }>}
 */
async function runSetupPreview(body, configAbsPath, options) {
  const deepVerify = options && options.deepVerify === true;
  const quickVerify = options && options.quickVerify === true;
  const built = buildFilesFromSetupBody(body, configAbsPath);
  validateKafkaConnectionCompleteness(body);
  let kafkaMaterializeResult = { mode: 'skipped' };
  if (hasFullKafkaConnection(body)) {
    kafkaMaterializeResult = materializeKafkaConnectionFiles(body, built.master);
  }
  const expanded = expandMasterToLegacy(built.master, configAbsPath);
  if (built.credentials && built.credentials.oc) {
    mergeOcFromCredentialsIntoGen(expanded.gen, built.credentials.oc);
  }

  const checks = [];
  const g = expanded.gen || {};
  const master = built.master;

  if (kafkaMaterializeResult.mode === 'full') {
    const km = kafkaMaterializeResult;
    const ts = km.truststoreSource === 'existing'
      ? `Truststore: using existing file at ${String(km.truststorePath || '').replace(/\\/g, '/')} (not uploaded). `
      : '';
    checks.push({
      id: 'kafka_wizard_materialized',
      level: 'ok',
      message: `${ts}Kafka client files from setup: ${(km.files || []).join(', ')} (Verify / Save).`,
    });
    if (truststoreUsesExistingFile(body) && km.truststorePath) {
      const vr = verifyTruststoreWithKeytool(km.truststorePath, body.kafkaTruststorePassword);
      checks.push(
        vr.ok
          ? {
            id: 'kafka_truststore_keytool',
            level: 'ok',
            message: 'Truststore: keytool -list OK (password opens JKS)',
          }
          : {
            id: 'kafka_truststore_keytool',
            level: 'error',
            message: `Truststore: keytool check failed — wrong password or invalid JKS: ${vr.message || 'unknown'}`,
          },
      );
    }
  }

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
    const pairs = collectOcContextNamespacePairs(master);
    const uniqPairs = new Set(pairs);
    if (pairs.length && uniqPairs.size !== pairs.length) {
      checks.push({
        id: 'oc_site_pairs_unique',
        level: 'error',
        message: 'Duplicate OpenShift target: same ocContext + namespace pair appears twice (each region/stage row must be unique).',
      });
    } else {
      checks.push({
        id: 'oc_contexts',
        level: 'ok',
        message: `OCP contexts (unique names): ${contexts.join(', ')} — same context name with different namespaces is allowed.`,
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
            message: `Client properties not found at ${clientPath} (needed for user validation flows; place under runtime configs/)`,
          }
    );
  }
  if (adminPath) {
    checks.push(
      fs.existsSync(adminPath)
        ? { id: 'kafka_admin_props', level: 'ok', message: `Admin properties found: ${adminPath}` }
        : {
            id: 'kafka_admin_props',
            level: deepVerify ? 'error' : 'warn',
            message: `Admin properties not found at ${adminPath} — portal "List topics" needs this file under runtime configs/ (error when running live verify)`,
          }
    );
    if (fs.existsSync(adminPath)) {
      checkTruststoreFromPropsFile(adminPath, checks);
      checkSensitiveFilePermissions(adminPath, checks, 'kafka_admin_props');
    }
  }
  if (clientPath && fs.existsSync(clientPath)) {
    checkSensitiveFilePermissions(clientPath, checks, 'kafka_client_props');
  }

  const scriptPath = resolveKafkaTopicsScriptPath(g);
  if (fs.existsSync(scriptPath)) {
    checks.push({ id: 'kafka_topics_script', level: 'ok', message: `kafka-topics.sh found: ${scriptPath}` });
  } else {
    checks.push({
      id: 'kafka_topics_script',
      level: deepVerify ? 'error' : 'warn',
      message: `kafka-topics.sh not found at ${scriptPath} — install Kafka bin under runtime or set kafka.clientInstallDir (error when running live verify)`,
    });
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

  if (deepVerify && quickVerify) {
    checks.push({
      id: 'verify_mode',
      level: 'ok',
      message: 'Quick verify: skipped live Kafka and OC calls (uncheck Quick verify for full cluster test)',
    });
  } else if (deepVerify) {
    const bs = String(g.bootstrapServers || '').trim();
    const topicsScript = resolveKafkaTopicsScriptPath(g);
    if (topicsScript && fs.existsSync(topicsScript) && adminPath && fs.existsSync(adminPath) && bs) {
      const r = spawnSync(
        topicsScript,
        ['--bootstrap-server', bs, '--command-config', adminPath, '--list'],
        { encoding: 'utf8', timeout: 25000, maxBuffer: 2 * 1024 * 1024, env: process.env }
      );
      if (r.error && r.error.code === 'ETIMEDOUT') {
        checks.push({
          id: 'kafka_list_topics',
          level: 'error',
          message: 'kafka-topics --list timed out — check bootstrap reachability, TLS/truststore, and admin SASL credentials',
        });
      } else if (r.status !== 0) {
        const err = ((r.stderr || r.stdout || '') + '').trim().slice(0, 400);
        checks.push({
          id: 'kafka_list_topics',
          level: 'error',
          message: `kafka-topics --list failed (same as portal topic list): ${err || `exit ${r.status}`}`,
        });
      } else {
        const n = (r.stdout || '').split('\n').map((t) => t.trim()).filter(Boolean).length;
        checks.push({
          id: 'kafka_list_topics',
          level: 'ok',
          message: `kafka-topics --list OK (${n} topic line(s))`,
        });
      }
    } else if (!bs) {
      checks.push({ id: 'kafka_list_topics', level: 'warn', message: 'Skipped live Kafka test: bootstrap servers empty' });
    }

    const kcExpanded = String(g.kubeconfigPath || '').trim();
    const ocEnv = kcExpanded && fs.existsSync(kcExpanded)
      ? { ...process.env, KUBECONFIG: kcExpanded }
      : process.env;
    if (kcExpanded && !fs.existsSync(kcExpanded)) {
      checks.push({
        id: 'kubeconfig_for_oc',
        level: 'warn',
        message: `Kubeconfig not found at ${kcExpanded} — oc uses default config paths; mount or fix path for predictable login`,
      });
    }
    if (contexts.length && fs.existsSync(ocExe)) {
      const ocTimeout = 20000;
      const whoamiResults = await Promise.all(
        contexts.map((ctx) => spawnWithTimeout(ocExe, ['whoami', '--context', ctx], ocEnv, ocTimeout).then((r) => ({ ctx, r })))
      );
      let whoamiFailureCount = 0;
      for (const { ctx, r } of whoamiResults) {
        if (r.status === 0) {
          const who = (r.stdout || '').split('\n')[0].trim();
          checks.push({ id: 'oc_whoami_' + ctx, level: 'ok', message: `oc whoami (${ctx}): ${who || 'ok'} (parallel)` });
        } else {
          whoamiFailureCount += 1;
          const err = ((r.stderr || r.stdout || '') + '').trim().slice(0, 300);
          const hint =
            /does not exist/i.test(err)
              ? ' Context name must match a NAME from `oc config get-contexts` for this kubeconfig (see oc_context_diagnostic below).'
              : '';
          checks.push({
            id: 'oc_whoami_' + ctx,
            level: 'error',
            message: `oc whoami failed for context "${ctx}" (secret updates need a valid login). ${err}.${hint}`,
          });
        }
      }
      if (whoamiFailureCount > 0 && kcExpanded && fs.existsSync(kcExpanded) && fs.existsSync(ocExe)) {
        const gr = spawnSync(ocExe, ['config', 'get-contexts', '--no-headers'], {
          encoding: 'utf8',
          timeout: 15000,
          maxBuffer: 256 * 1024,
          env: ocEnv,
        });
        const present = parseContextNamesFromGetContextsStdout(gr.stdout);
        const missing = contexts.filter((c) => !present.includes(c));
        const kcEsc = kcExpanded.replace(/"/g, '\\"');
        let diag =
          `Kubeconfig "${kcExpanded}" vs setup: required ocContext=[${contexts.join(', ')}]; ` +
          `names present in file=[${present.length ? present.join(', ') : '(none or unreadable)'}]; ` +
          `missing from file=[${missing.length ? missing.join(', ') : '—'}]. ` +
          `Fix: merge kubeconfigs / oc login so each required name exists, or change environments fallbackSites/sites ocContext to match an existing NAME. ` +
          `Confirm on host (same file as container): KUBECONFIG="${kcEsc}" oc config get-contexts` +
          ` && KUBECONFIG="${kcEsc}" oc whoami --context '<name>'.`;
        if (gr.status !== 0) {
          const ge = ((gr.stderr || gr.stdout || '') + '').trim().slice(0, 220);
          diag += ` (oc config get-contexts failed: ${ge})`;
        }
        checks.push({ id: 'oc_context_diagnostic', level: 'error', message: diag });
      }
    }
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
