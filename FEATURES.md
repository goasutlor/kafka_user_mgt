# Features & capabilities (public overview)

This document describes what **Confluent Kafka User Management** offers for **operators** and **platform teams**. It is safe to share publicly — it contains **no customer-specific hosts, namespaces, or credentials**.

---

## Architecture (summary)

- **Single container image** — Web UI (Node.js) + bundled automation script (`gen.sh`) + Kafka CLI tools.
- **Configuration-driven** — Kafka bootstrap URLs, OpenShift contexts, namespaces, and optional multi-environment IDs come from **your** mounted config (`master.config.json`, `environments.json`, properties files, kubeconfig).
- **CLI / Web parity** — The same engine backs the Portal APIs and the supported CLI entry points (see `README.md`).

---

## Web Portal

| Area | Features |
|------|----------|
| **Setup** | First-time wizard to write `master.config.json`, credentials layout, Kafka property paths, portal port/HTTPS, optional auth. |
| **Environments** | Optional multi-environment switch (e.g. Dev / SIT / UAT) with per-environment bootstrap and file naming. |
| **Provisioning** | Create topic; add user (with ACL presets or advanced ACL JSON); add ACL to existing user; combined topic + onboard flows where implemented. |
| **User management** | Test user; change password; remove user(s); cleanup orphaned ACLs. |
| **Reporting** | Audit log (JSON lines); download history for generated `.enc` packs; operational checks (e.g. preflight / go-live scripts where enabled). |

---

## Automation script (`gen.sh`)

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
