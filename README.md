# Confluent Kafka User Management

Web UI + `gen.sh` for Confluent Kafka user / topic / ACL operations against OpenShift-hosted clusters.

## Container image (GHCR)

After CI runs on `main`, pull:

```bash
docker pull ghcr.io/goasutlor/kafka_user_mgt:latest
```

Run with Compose (mount `runtime` + `deploy/config`). First start: open `http://<host>:3443/setup.html` to write config into the mounted volume. **Upgrading the image keeps that config** (no re-setup). To wipe and run setup again: **`/reset-config.html`** (Portal user/password + confirmation phrase), or see [UPGRADE-AND-PERSISTENCE.md](UPGRADE-AND-PERSISTENCE.md).

### CLI (Portal-parity wrappers)

- `./scripts/gen-in-container.sh` — runs bundled `gen.sh` in the running container with Portal-compatible baseline env (`PATH`, `GEN_OC_PATH`, `KUBECONFIG`, `GEN_BASE_DIR`). Before `gen.sh`, it sources **`portal-parity-env.sh`** inside the container so **default OCP sites / active environment** match the Portal when you have not set `GEN_OCP_SITES` (uses `environments.json` under the runtime mount, else `master.config.json`).
- `./scripts/gen-cli.sh` — guided menu wrapper for common non-interactive flows (preflight, test user, add ACL existing, guided add user) and environment profile selection from `master.config`.

**VM / host without a git checkout:** the same two scripts ship in the image under `/app/host-cli/`. Copy both to the same directory on the host, then run from there (example: container name `kafka-user-mgmt`):

```bash
podman cp kafka-user-mgmt:/app/host-cli/gen-in-container.sh ~/kafka-cli/
podman cp kafka-user-mgmt:/app/host-cli/gen-cli.sh ~/kafka-cli/
chmod +x ~/kafka-cli/gen-in-container.sh ~/kafka-cli/gen-cli.sh
export CTR_ENGINE=podman CONTAINER_NAME=kafka-user-mgmt
~/kafka-cli/gen-cli.sh
```

**Upgrades / full reset:** Pulling a newer image does not wipe bind-mounted host config. For a clean reinstall (drop old `master.config` / kubeconfig paths), see [UPGRADE-AND-PERSISTENCE.md](UPGRADE-AND-PERSISTENCE.md) — section *รีเซ็ตเริ่มใหม่ทั้งหมด* (Thai + English).

**Topology:** Dual DC / dual OpenShift with **one** Confluent Kafka cluster — production fit and “universal portal” limits — see [PRODUCTION-TOPOLOGY-2DC-1-KAFKA.md](PRODUCTION-TOPOLOGY-2DC-1-KAFKA.md).

**`gen.sh` is part of the container image only** (`/app/bundled-gen/gen.sh` via `Dockerfile` / `GEN_BUNDLED_SCRIPT_PATH`). The host runtime mount (`./runtime` → `/opt/kafka-usermgmt`) is for configs, kubeconfig, `user_output`, certs — **do not put or expect `gen.sh` there.** `master.config` may still describe `runtimeRoot` under `/opt/kafka-usermgmt`; the Node server runs the bundled script unless you set `GEN_USE_HOST_SCRIPT=1` and provide a script at the configured path.

The directory `kafka_from_host/` (if present locally) is only a host mirror and is **not** committed to git; the container image installs Kafka CLI from Apache at build time.

If the package is **private**, authenticate: `echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin`

### หลัง push — รอให้ CI build GHCR เสร็จ / Wait until GHCR build finishes

หลัง `git push` ไป `main` (หรือ `master`) workflow จะ build ที่ GitHub Actions ถ้าต้องการรอจนเสร็จแล้วเห็นผลสำเร็จ/ล้มเหลวในเทอร์มินัล:

- **PowerShell (Windows):** `.\scripts\wait-ghcr-build.ps1`
- **Bash / Git Bash / WSL:** `./scripts/wait-ghcr-build.sh`

ต้องติดตั้ง [GitHub CLI](https://cli.github.com/) และล็อกอินแล้ว (`gh auth login`) ถ้าเป็น fork ให้ตั้ง `GITHUB_REPO=owner/name` ก่อนรันสคริปต์ bash หรือ `$env:GITHUB_REPO = "owner/name"` ใน PowerShell

## Build locally

```bash
docker build -t kafka-user-mgt:local .
```

See `docker-compose.yml` and `Dockerfile` for details.

---

## Deployment & migration checklist

Use this when **moving the portal to a new host**, changing bind-mount paths, or adding environments that use **different Kafka clusters**.

### Two mount roles (typical)

| Role | Example in container | Host directory (you choose) |
|------|----------------------|-----------------------------|
| **Portal config** | Often `/app/config` (`CONFIG_PATH` → `master.config.json`) | e.g. `kafka-usermgmt-config/` |
| **Runtime (`runtimeRoot`)** | `/opt/kafka-usermgmt` | e.g. `kafka-usermgmt-runtime/` |

`master.config.json` sets `runtimeRoot` (e.g. `/opt/kafka-usermgmt`). Kafka CLI configs, kubeconfig, `user_output`, and synced `environments.json` live **under that runtime root**, not necessarily next to `master.config.json`.

### Copy or recreate (minimum)

1. **`master.config.json`** — adjust if paths, ports, or topology change on the new host.
2. **`credentials.json`** (next to master) — portal auth; optional OC secrets if you use `server.auth.secretsFile` merge.
3. **Kafka properties under `{runtimeRoot}/configs/`**  
   - Single-env / `environments.enabled: false`: default names from master `kafka.clientPropertiesFile` / `kafka.adminPropertiesFile` (e.g. `kafka-client.properties`, `kafka-client-master.properties`).  
   - **Multi-env / `environments.enabled: true`**: runtime uses **`kafka-client-{envId}.properties`** and **`kafka-client-master-{envId}.properties`** where **`envId` matches** the environment `id` in master. **Web Setup** (Save / Verify with Kafka filled in) **writes these files automatically** — shared truststore + SASL, per-row `bootstrap.servers`. Templates-only save creates per-env `CHANGE_ME` templates too. The app does **not** scan the disk for suffixes; it maps **`id` ↔ filename**.
4. **Truststore / TLS material** — e.g. `client.truststore.jks` or paths referenced inside the `.properties` files; copy or update `ssl.truststore.location` if the new layout differs.
5. **Kubeconfig** — file at expanded `oc.kubeconfig` (e.g. `{runtimeRoot}/.kube/config` or `config-both`). Context **names** must match `ocContext` values in `fallbackSites` or `environments[].sites[]`.
6. **`oc.loginServers`** in master — API URLs per context if clusters or API endpoints change.
7. **`environments` block** — `enabled`, `defaultEnvironmentId`, each entry: `id`, `sites`, optional `bootstrapServers`, optional overrides (`adminPropertiesFile`, etc.).
8. **HTTPS** (if enabled) — `portal.https.keyPath` / `certPath` and mounted cert files inside the container.
9. **Container run** — volumes, published port, image tag after code changes (see below).

After changing **application code** (Node server or bundled `gen.sh`), **rebuild the image** (or bind-mount updated sources and restart) so behavior such as per-env property paths and `GEN_KAFKA_BOOTSTRAP` parity is present in the running container.

---

## When manual work is still required (important)

The **Setup wizard** can finish **multi-environment Kafka file layout** when you use **one shared truststore + SASL** and **different bootstrap per environment** (it writes `kafka-client-{id}.properties` / `kafka-client-master-{id}.properties` on Save). These cases still need **manual or ops-owned** work:

| Situation | Why manual |
|-----------|------------|
| **Different SASL users or truststores per environment** | Setup writes the **same** credentials into every env file. If **admin or client password differs per cluster**, edit the generated files (or use `adminPropertiesFile` / `clientPropertiesFile` overrides in master). |
| **Corporate truststore / CA** | You must supply JKS/PEM (or place `.jks` on the mount); Setup does not obtain your CA from the network. |
| **Kubeconfig and OpenShift contexts** | The portal does not create contexts; merge or copy kubeconfig and ensure **context names** match configuration. |
| **Topics exist only on some clusters** | Operations: create the topic on each cluster where you need it; CLI `kafka-topics --describe` per bootstrap is the sanity check. |
| **Moving servers / new paths** | Reconcile **all** paths in master + properties + volumes; see checklist above. |
| **Skipping Setup entirely** | Hand-edit master + `configs/*.properties` yourself. |

**Summary:** For the common case (**shared Kafka TLS/SASL, different bootstrap per env**), **Web Setup is enough** for property files. Divergent credentials per cluster still need **manual edits** after save or separate tooling.
