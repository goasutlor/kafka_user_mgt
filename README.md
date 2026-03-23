# Confluent Kafka User Management

Web UI + `gen.sh` for Confluent Kafka user / topic / ACL operations against OpenShift-hosted clusters.

## Container image (GHCR)

After CI runs on `main`, pull:

```bash
docker pull ghcr.io/goasutlor/kafka_user_mgt:latest
```

Run with Compose (mount `runtime` + `deploy/config`). First start: open `http://<host>:3443/setup.html` to write config into the mounted volume. **Upgrading the image keeps that config** (no re-setup). To wipe and run setup again: **`/reset-config.html`** (Portal user/password + confirmation phrase), or see [UPGRADE-AND-PERSISTENCE.md](UPGRADE-AND-PERSISTENCE.md).

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
