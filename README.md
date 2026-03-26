# Confluent Kafka User Management

Web UI + `gen.sh` for Confluent Kafka user / topic / ACL operations against OpenShift-hosted clusters.

**Public docs:** [FEATURES.md](FEATURES.md) (capability overview) · [HANDOVER.md](HANDOVER.md) (operator handover) · [SECURITY.md](SECURITY.md) (no secrets in git).

## Container image (GHCR)

After CI runs on `main`, pull:

```bash
docker pull ghcr.io/goasutlor/kafka_user_mgt:latest
```

Run with Compose (mount `runtime` + `deploy/config`). First start: open `http://<host>:3443/setup.html` to write config into the mounted volume. **Upgrading the image keeps that config** (no re-setup). To wipe and run setup again: **`/reset-config.html`** (Portal user/password + confirmation phrase), or see [UPGRADE-AND-PERSISTENCE.md](UPGRADE-AND-PERSISTENCE.md).

**Universal / no vendor lock-in:** Kafka bootstrap, OpenShift contexts, and namespaces come from **your** `master.config.json` (Setup) and synced `environments.json` — not from hardcoded hostnames in `gen.sh`. The bundled CLI (`gen-in-container.sh`) applies the same defaults as the Portal via `portal-parity-env.sh`. For merged multi-cluster kubeconfigs, set `GEN_KUBECONFIG_MERGE_BOTH=1` to use a sibling `config-both` file if you use that layout.

### CLI (Podman `exec` — supported path)

Automation always runs **inside the running container** via `podman exec` (or `docker exec`). The helper scripts live in **this repository** and call `podman exec` for you with the correct `PATH`, `GEN_BASE_DIR`, `KUBECONFIG`, and `portal-parity-env.sh` — the same baseline the Portal uses.

**Do not** copy `gen-in-container.sh` / `gen-cli.sh` out of the image onto arbitrary host directories. That creates drift (image vs copied file), is hard to control in reviews, and is **not** the supported workflow.

| Script | Purpose |
|--------|---------|
| `scripts/podman-gen.sh` | **Recommended (Podman).** Interactive `gen.sh` with portal parity. |
| `scripts/podman-gen-cli.sh` | **Recommended (Podman).** Menu + optional `[environment-id]` (matches `master.config` → `environments.environments[].id`), then `gen.sh`. |
| `scripts/gen-in-container.sh` | Same as `podman-gen.sh`, but auto-detects **Podman or Docker** (`CTR_ENGINE`). |
| `scripts/gen-cli.sh` | Same as `podman-gen-cli.sh`, but auto-detects Podman or Docker. |

From a **git clone** on your workstation (Linux / WSL / Git Bash), with the app container already running (e.g. `CONTAINER_NAME=kafka-user-mgmt`):

```bash
chmod +x scripts/podman-gen.sh scripts/podman-gen-cli.sh scripts/gen-in-container.sh scripts/gen-cli.sh
./scripts/podman-gen.sh
# or
./scripts/podman-gen-cli.sh your-env-id
```

Optional: `CONTAINER_NAME`, `KUBECONFIG` (path **inside** the container), `GEN_BASE_DIR` — see `scripts/gen-in-container.sh` header.

**Without a git clone:** use a single `podman exec` (no file copy). Replace `<container>` with your container name:

```bash
podman exec -it \
  -e PATH=/usr/local/bin:/usr/bin:/bin:/host/usr/bin \
  -e GEN_OC_PATH=/host/usr/bin/oc \
  -e KUBECONFIG=/opt/kafka-usermgmt/.kube/config \
  -e GEN_BASE_DIR=/opt/kafka-usermgmt \
  <container> \
  bash -lc 'source /app/host-cli/portal-parity-env.sh 2>/dev/null || true; exec /app/bundled-gen/gen.sh'
```

**Upgrades / full reset:** Pulling a newer image does not wipe bind-mounted host config. For a clean reinstall (drop old `master.config` / kubeconfig paths), see [UPGRADE-AND-PERSISTENCE.md](UPGRADE-AND-PERSISTENCE.md) (full reset section).

**Topology:** Dual DC / dual OpenShift with **one** Confluent Kafka cluster — production fit and “universal portal” limits — see [PRODUCTION-TOPOLOGY-2DC-1-KAFKA.md](PRODUCTION-TOPOLOGY-2DC-1-KAFKA.md).

**`gen.sh` is part of the container image only** (`/app/bundled-gen/gen.sh` via `Dockerfile` / `GEN_BUNDLED_SCRIPT_PATH`). The host runtime mount (`./runtime` → `/opt/kafka-usermgmt`) is for configs, kubeconfig, `user_output`, certs — **do not put or expect `gen.sh` there.** `master.config` may still describe `runtimeRoot` under `/opt/kafka-usermgmt`; the Node server runs the bundled script unless you set `GEN_USE_HOST_SCRIPT=1` and provide a script at the configured path.

The directory `kafka_from_host/` (if present locally) is only a host mirror and is **not** committed to git; the container image installs Kafka CLI from Apache at build time.

If the package is **private**, authenticate: `echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin`

### After push — wait for GHCR image build

After `git push` to `main` (or your release branch), GitHub Actions builds the image. To wait until the run finishes:

- **PowerShell (Windows):** `.\scripts\wait-ghcr-build.ps1`
- **Bash / Git Bash / WSL:** `./scripts/wait-ghcr-build.sh`

Requires [GitHub CLI](https://cli.github.com/) (`gh auth login`). For a fork, set `GITHUB_REPO=owner/name` before running the bash script, or `$env:GITHUB_REPO = "owner/name"` in PowerShell.

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
