# Confluent Kafka User Management

Web UI + `gen.sh` for Confluent Kafka user / topic / ACL operations against OpenShift-hosted clusters.

## Container image (GHCR)

After CI runs on `main`, pull:

```bash
docker pull ghcr.io/goasutlor/kafka_user_mgt:latest
```

Run with Compose (mount `runtime` + `deploy/config`). First start: open `http://<host>:3443/setup.html` to write config into the mounted volume.

**Upgrades / full reset:** Pulling a newer image does not wipe bind-mounted host config. For a clean reinstall (drop old `master.config` / kubeconfig paths), see [UPGRADE-AND-PERSISTENCE.md](UPGRADE-AND-PERSISTENCE.md) — section *รีเซ็ตเริ่มใหม่ทั้งหมด* (Thai + English).

**Topology:** Dual DC / dual OpenShift with **one** Confluent Kafka cluster — production fit and “universal portal” limits — see [PRODUCTION-TOPOLOGY-2DC-1-KAFKA.md](PRODUCTION-TOPOLOGY-2DC-1-KAFKA.md).

The directory `kafka_from_host/` (if present locally) is only a host mirror and is **not** committed to git; the container image installs Kafka CLI from Apache at build time.

If the package is **private**, authenticate: `echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin`

## Build locally

```bash
docker build -t kafka-user-mgt:local .
```

See `docker-compose.yml` and `Dockerfile` for details.
