# Features & capabilities (public overview)

This document describes what **Confluent Kafka User Management** offers for **operators** and **platform teams** — especially **what the Web Portal can do**, not only how to run it. It is safe to share publicly: no customer-specific hosts, namespaces, or credentials.

---

## Architecture (summary)

- **Single container image** — Web UI (Node.js) + bundled automation script (`gen.sh`) + Kafka CLI tools.
- **Configuration-driven** — Kafka bootstrap URLs, OpenShift contexts, namespaces, and optional multi-environment IDs come from **your** mounted config (`master.config.json`, `environments.json`, properties files, kubeconfig).
- **CLI / Web parity** — The same engine backs the Portal APIs and the supported CLI entry points (see `README.md`).

---

## Web Portal — what it does (functions)

The main UI is served by the container (typically port **3443**). Below is what operators can do **in the browser** after the service is configured.

### Access, session, and environment

| Function | Description |
|----------|-------------|
| **Sign-in** | Optional portal authentication (local users / credentials file) when enabled in config. |
| **Environment selection** | When **multi-environment** mode is enabled in `master.config.json`, the user picks which logical environment (e.g. Dev / SIT / UAT) applies for **this session** — Kafka bootstrap, property files, namespaces, and outputs are scoped to that id. |
| **Environment badge** | Header shows which environment is active (tier hints from naming where applicable). |
| **Version** | UI shows application version (and optional git short hash) so operators know which image build is running. |
| **Logout** | Ends the session. |

### Standalone pages (outside the main hash router)

| Page | Function |
|------|----------|
| **`/setup.html`** | **First-time setup wizard** — writes `master.config.json`, credentials layout, Kafka paths, `oc` / kubeconfig settings, portal port, optional HTTPS, multi-environment definitions, and materialises Kafka client/admin property files where applicable. |
| **`/reset-config.html`** | **Controlled wipe** of saved portal configuration (requires portal credentials + confirmation phrase when auth is enabled). Use when intentionally rebuilding from scratch — **not** done by routine image upgrades. |

### Home (dashboard)

- Quick links to main workflows: create topic & onboard, add user, audit, downloads, documentation (where linked).
- Overview tiles summarising provisioning and reporting areas.

### Provisioning (main application pages)

| Page / flow | What it does |
|-------------|----------------|
| **Create Topic & Onboard User** | Guided wizard: create a Kafka **topic** (broker defaults for partitions / replication), then **add a user** with ACLs and produce an **encrypted client pack** (`.enc`) — end-to-end onboarding in one flow. |
| **Add new user** | Multi-step wizard: system/topic identification, Kafka **username**, **ACL design** (presets such as consumer/producer-style bundles or **advanced** resource-based ACL JSON), passphrase for the `.enc` pack, then execute. Optional streaming progress for long runs. |
| **Add ACL to existing user** | For a user that **already exists** in the platform secret: add **topic** and **consumer group** ACLs (presets or advanced config) **without** creating a new credential. Can preview/list-related ACL context. |
| **Test existing user** | Validate **username / password** against Kafka (and topic) using the configured client properties — sanity check after provisioning or changes. |
| **Remove user(s) + ACL** | Remove one or more users from the **plain-users** secret across configured OpenShift sites and **remove associated ACLs** (with validation to avoid inconsistent state). |
| **Change password** | Rotate password for an existing user on all sites, issue a **new** encrypted pack. |
| **Cleanup orphaned ACLs** | Find ACLs for principals that no longer exist in the user secret and **remove** those ACLs (housekeeping). |

### ACL and topic helpers (within wizards)

- **Load topic list** / **filter** — Calls the broker (admin client) to list topics for pickers and validation.
- **Load existing users** / **filter** — Reads user keys from the configured secret(s) for pickers.
- **ACL presets** — Role-style bundles (e.g. read-heavy vs producer vs broader) aligned with CLI defaults; optional **ACL designer** for custom operations and resources.
- **Copy command** — Optional preview of low-level ACL command text for advanced operators (parity with tooling expectations).

### Reporting and compliance

| Page | What it does |
|------|----------------|
| **Audit Log** | Table of **time, action, who, system, topic, target** — actions such as add user, create topic, remove user, change password, test user, cleanup ACL, add ACL to existing user. Filterable by date (GMT+7). Records portal-driven activity; CLI can append to the same store when configured (see technical docs). |
| **Download History** | Lists generated **`.enc`** packs by day with **download** links (and optional merge with discovered files under the per-environment output directory). |

### Operational APIs used by the UI (conceptual)

The Portal calls REST APIs such as: environments, users list, topics list, add-user (including streaming), create-topic, test-user, remove-user, change-password, cleanup-acl, add-acl-existing-user, list-acls, audit-log, download-history, download pack, version, setup status — **you do not need to call these manually** for normal operation; they are documented implicitly by the features above.

---

## Automation script (`gen.sh`) — CLI parity

Interactive menu and **non-interactive** mode via environment variables (`GEN_MODE`, `GEN_NONINTERACTIVE`, etc.):

| Mode | Typical use |
|------|----------------|
| Add user | Password generation, multi-site Secret patch, ACLs, optional broker validation, encrypted client pack. |
| Test user | Credential and topic validation. |
| User management | Remove users, change password, cleanup ACLs. |
| Create topic | Topic creation with broker defaults for partitions/replication. |
| Add ACL (existing user) | Topic + group ACLs without new credentials. |
| Preflight / admin checks | Kafka admin connectivity (e.g. topic list). |
| Go-live / verify | Scripted checks across configured namespaces (when configured). |
| Client property templates | Helper to scaffold Kafka client/admin property files (full TLS/SASL materialization via Setup where applicable). |
| Config reset | CLI helper for portal config wipe (when auth requirements are met). |

### How to run the CLI (supported)

Use **`podman exec`** (or `docker exec`) into the running app container — **not** a copy of scripts taken off the image to random host paths. From a git checkout, prefer **`scripts/podman-gen.sh`** (interactive `gen.sh`) or **`scripts/podman-gen-cli.sh`** (menu + optional environment id). See **`README.md`** for the full table and a one-liner if you have no clone.

---

## OpenShift / Kubernetes integration

- Uses **`oc`** (typically **host binary** mounted into the container) against contexts/namespaces **you** define.
- **Multi-site** — Same logical Kafka user replicated across multiple clusters/namespaces via configured site list.
- **Secrets** — Updates `plain-users.json` (or configured key) in the target Secret; behaviour is aligned with Confluent-style deployments that use this pattern.

---

## Kafka integration

- **SASL / TLS** — Standard Java client properties for admin and client operations.
- **ACLs** — Topic and consumer group ACLs with preset bundles or custom resource definitions (aligned between Web and CLI where supported).
- **Multi-environment** — Different `bootstrap.servers` per environment ID when configured.

---

## Security & governance notes

- **Do not commit** real kubeconfigs, keystores, passwords, or internal API URLs — use private mounts or secret stores.
- See **`SECURITY.md`** in this repository for redaction and contribution guidelines.

---

## Further reading

- **`README.md`** — Image pull, volumes, CLI wrappers, deployment checklist.
- **`HANDOVER.md`** — Operator / customer handover narrative (English).
- **`UPGRADE-AND-PERSISTENCE.md`**, **`PRODUCTION-TOPOLOGY-2DC-1-KAFKA.md`** — Deeper operational topics where present.
