# Confluent Kafka User Management — Customer Handover Guide

**English · Markdown** — Use this document when transferring operations or ownership of the solution to your customer or another team.

---

## 1. What this solution is

**Confluent Kafka User Management** is a packaged application that helps operators manage **Kafka SASL/PLAIN users** and **ACLs** in environments where **Confluent for Kubernetes (CFK)** (or equivalent) stores credentials in an OpenShift **Secret** (`plain-users.json`), and Kafka runs against **one or more OpenShift clusters** connected to the **same Kafka cluster** (typical multi–data-centre or multi–namespace layouts).

It provides:

| Channel | Description |
|--------|-------------|
| **Web Portal** | Browser UI for guided workflows, configuration (Setup wizard), and reporting. |
| **CLI** | The same automation engine (`gen.sh`) run inside the application container or via helper scripts — **feature parity** with the Portal for supported operations. |

Configuration is **not hard-coded to vendor hostnames**: Kafka bootstrap URLs, OpenShift contexts/namespaces, and optional **multiple logical environments** (Dev / SIT / UAT / Prod-style IDs) come from **your** `master.config.json` and related files on mounted volumes.

---

## 2. What the product can do (capabilities)

### 2.1 User lifecycle (Kafka + OpenShift)

- **Add user** — Generate a secure password, patch `plain-users.json` in the configured Secret **across all configured OpenShift sites** (contexts/namespaces), apply **Kafka ACLs** (topic + consumer group patterns as per presets or advanced ACL definitions), optionally validate against the broker (auth / consume), and produce an **encrypted client pack** (`.enc`) for the client team.
- **Test existing user** — Verify credentials and topic access using Kafka client tooling.
- **Change password** — Rotate password in all secrets and **re-issue** an encrypted pack; designed with safe **multi-site** failure handling.
- **Remove user(s)** — Remove users from secrets and **remove associated ACLs**; supports batch removal with validation.
- **Add ACL to existing user** — Grant additional topic/group ACLs for a user that already exists in the Secret (no new credential).

### 2.2 Topics

- **Create topic** — Create a Kafka topic using **broker defaults** for partitions and replication (rack-aware placement where applicable).
- **Create topic & onboard user** — Combined wizard flow on the Portal (topic + user onboarding) aligned with the same validation rules as the CLI.

### 2.3 ACL hygiene

- **Cleanup orphaned ACLs** — List ACLs for principals that no longer exist in `plain-users.json` and remove them (read-only sanity checks before destructive steps).

### 2.4 OpenShift / platform

- **Multi-site** — Operate against **multiple** `oc` contexts and namespaces from a **single** configuration (comma-separated `GEN_OCP_SITES` or equivalent from `master.config.json` / `environments.json`).
- **OpenShift CLI** — Uses the **host’s `oc`** mounted into the container (typical deployment pattern) so logins and contexts match your cluster access model.

### 2.5 Kafka connectivity

- **TLS / SASL** — Uses standard **client** and **admin** properties files (per environment when multi-env is enabled).
- **Multi-environment bootstrap** — Different **bootstrap servers** per environment ID when configured (e.g. Dev vs UAT clusters).

### 2.6 Portal-specific features

- **First-time Setup wizard** — Writes `master.config.json`, Kafka property templates, and related paths onto the **mounted config volume** (survives image upgrades).
- **Portal authentication** — Optional local user/password (and related auth configuration) stored alongside master config.
- **Multi-environment switcher** — When enabled, **Dev / SIT / UAT**-style environments share one Portal but use **separate** Kafka files, per-env `user_output`, and per-env **audit / download history** where configured.
- **Audit log** — JSON lines per action (who, action, topic, target, etc.) for Portal-driven actions; **CLI** actions can append to the **same** audit store when the runtime is aligned (see technical README).
- **Download history** — Lists generated `.enc` packs with download links; can merge **recorded history** and **discovered** packs under the per-environment output directory.
- **Operational reports** — e.g. **Go-Live** / preflight style checks (where enabled in your build and configuration).

### 2.7 CLI parity

- **Same engine** — `gen.sh` (bundled in the image) backs both Portal API calls and CLI entry points.
- **Helper scripts** (`gen-in-container.sh`, `gen-cli.sh`) — Run the bundled script from the **host** with `PATH`, `KUBECONFIG`, `GEN_BASE_DIR`, and **portal-parity** environment so defaults match the **Portal** (active environment, OCP sites, audit paths when applicable).

### 2.8 Explicit non-goals / limits

- The tool **does not** create OpenShift projects, Kafka clusters, or CFK CRs from scratch; it **expects** namespaces, Secrets, and broker connectivity to exist per your platform design.
- **Different SASL identities or truststores per environment** may require **manual** property edits after Setup — the wizard optimises the common case (shared material, different bootstrap per env).
- **Kubeconfig contexts** must be prepared by the customer; the app does not auto-generate cluster credentials.

---

## 3. How it is delivered

- **Container image** (e.g. `ghcr.io/goasutlor/kafka_user_mgt`) — **Node.js** web server + static UI + **bundled** `gen.sh` + Kafka command-line tools.
- **Persistent data** — Bind mounts for **config** (`master.config.json`, credentials, per-environment files) and **runtime** (kubeconfig, Kafka TLS/SASL material, `user_output`, `environments.json`, logs).
- **Upgrades** — Pulling a newer image **does not** remove mounted configuration; follow your internal change process and the project’s **upgrade / persistence** notes if present in the repository.

---

## 4. Prerequisites (customer / operations)

- **OpenShift** (or compatible Kubernetes with `oc`) access and **namespace(s)** where the Secret(s) live.
- **Kafka** reachable from the container (network + firewall rules).
- **Kafka admin** and **client** properties (truststore, SASL) consistent with your security policy.
- **TLS material** and **corporate CA** trust as required by your organisation.
- A host or VM for **Podman** or **Docker** (or equivalent) to run the container.

---

## 5. Handover checklist (suggested)

1. Confirm **image tag** and **digest** recorded in your release documentation.
2. Document **mount paths** on the host for **config** and **runtime** volumes.
3. Store **Portal admin** credentials and **recovery** procedure (reset / wipe pages if used).
4. Record **OpenShift contexts** and **namespace** names per site and per environment ID.
5. **Smoke test**: Setup (if new), **Preflight** / topic list, **Add user** (non-prod), **Test user**, **Download** pack, **Audit log** entry.
6. Align **runbooks** for password rotation, user removal, and cluster DR (kubeconfig rotation).

---

## 6. Further technical documentation

Inside the same repository you will typically find:

| Document | Typical content |
|----------|-----------------|
| `README.md` | Image pull, Compose, CLI wrappers, deployment checklist, migration notes. |
| `UPGRADE-AND-PERSISTENCE.md` | Upgrades and full reset. |
| `PRODUCTION-TOPOLOGY-2DC-1-KAFKA.md` | Dual DC / dual OpenShift with one Kafka cluster. |

Use those for **implementation detail**; use **this handover guide** for **stakeholder-facing** scope and capability.

---

## 7. Support and versioning

- Application **version** is shown in the Portal UI (and may be exposed via `/api/version` depending on deployment).
- For **defects or enhancements**, track against your internal **change management** process and the **version** of the container image in use.

---

*This document describes the **intended** behaviour of the Confluent Kafka User Management solution. Exact behaviour in your environment depends on configuration, network policy, and broker/CFK versions.*
