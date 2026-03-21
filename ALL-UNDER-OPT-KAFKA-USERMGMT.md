# Using only /opt/kafka-usermgmt (no /app/user2 reference)

When everything lives under `/opt/kafka-usermgmt` (including `kafka_2.13-3.6.1` and `.kube`), you can avoid any reference to `/app/user2/kotestkafka`.

---

## 1. What was changed in the repo

- **gen.sh (confluent-usermanagement.sh)**  
  Default `BASE_DIR` is now the **script directory** (`SCRIPT_DIR`), not `/app/user2/kotestkafka`. So when you run the script from `/opt/kafka-usermgmt`, it uses that path without setting `GEN_BASE_DIR`.

- **podman_runconfig.sh**  
  If `KUBE_DIR` is under `ROOT` (e.g. `KUBE_DIR=/opt/kafka-usermgmt/.kube`), the script **does not** add a separate mount to `/app/user2/.kube`. The `.kube` directory is already visible under the `ROOT` mount at `/opt/kafka-usermgmt/.kube` inside the container.

---

## 2. What you must do on your machine

### 2.1 Put .kube under ROOT

Place your kubeconfig under the same root as the rest of the app, for example:

```text
/opt/kafka-usermgmt/.kube/
  config-both   (or whatever file name you use)
```

`podman_runconfig.sh` already defaults `KUBE_DIR` to `$ROOT/.kube`, so no change needed there if you use this layout.

### 2.2 Edit Docker/web.config.json

Use **paths as seen inside the container**. With `ROOT=/opt/kafka-usermgmt` and the default mounts, the container sees:

- `/opt/kafka-usermgmt` (script, configs, kafka_2.13-3.6.1, user_output, .kube, etc.)
- `/app/config` = Docker folder (web.config.json, audit.log, etc.)
- `/app/ssl` = server.key, server.crt

So in `Docker/web.config.json` set `gen` like this (no `/app/user2`):

```json
"gen": {
  "scriptPath": "/opt/kafka-usermgmt/confluent-usermanagement.sh",
  "baseDir": "/opt/kafka-usermgmt",
  "downloadDir": "/opt/kafka-usermgmt",
  "kafkaBin": "/opt/kafka-usermgmt/kafka_2.13-3.6.1/bin",
  "clientConfig": "/opt/kafka-usermgmt/configs/kafka-client.properties",
  "adminConfig": "/opt/kafka-usermgmt/configs/kafka-client-master.properties",
  "logFile": "/opt/kafka-usermgmt/provisioning.log",
  "kubeconfigPath": "/opt/kafka-usermgmt/.kube/config-both",
  ...
}
```

Important: **kubeconfigPath** is `/opt/kafka-usermgmt/.kube/config-both` only when `.kube` is under ROOT and you use the default `KUBE_DIR=$ROOT/.kube`. Then no separate `.kube` mount is used and there is no `/app/user2` path.

### 2.3 podman_runconfig.sh

Keep default:

```bash
export ROOT="${ROOT:-/opt/kafka-usermgmt}"
```

No need to set `KUBE_DIR` if `.kube` is at `$ROOT/.kube`.

### 2.4 configs/*.properties (certs path)

Kafka client configs (`configs/kafka-client-master.properties`, etc.) contain `ssl.truststore.location` and `ssl.truststore.password`. Those paths must point to **paths inside the container** (e.g. `/opt/kafka-usermgmt/certs/kafka-truststore.jks`). If you still have `/app/user2/kotestkafka/certs/...` in those files, list topics and add-user will fail with `NoSuchFileException`. Either edit the files by hand or run `scripts/migrate-to-opt.sh` (it rewrites both `Docker/web.config.json` and `configs/*.properties`).

### 2.5 BASE_HOST

`podman_runconfig.sh` passes `-e BASE_HOST=$BASE_HOST` into the container so the server can use it when `gen.baseDir` is missing. Default in code is `/opt/kafka-usermgmt`.

---

## 3. Summary: what still referenced /app/user2 and what no longer does

| Item | Before | After (all under /opt/kafka-usermgmt) |
|------|--------|--------------------------------------|
| gen.sh default BASE_DIR | /app/user2/kotestkafka | Script directory (e.g. /opt/kafka-usermgmt) |
| web.config.json gen.* paths | /app/user2/kotestkafka/... | /opt/kafka-usermgmt/... |
| web.config.json kubeconfigPath | /app/user2/.kube/config-both | /opt/kafka-usermgmt/.kube/config-both |
| podman .kube mount | Always -v KUBE_DIR:/app/user2/.kube | Only if KUBE_DIR is **outside** ROOT; otherwise .kube is under ROOT mount |
| configs/*.properties ssl.truststore.location | /app/user2/kotestkafka/certs/... | /opt/kafka-usermgmt/certs/... (or run migrate-to-opt.sh) |

With this, nothing needs to reference `/app/user2` anymore.

---

## 4. Download History and Audit Log (CLI + Web)

- **Download History:** The API merges entries from `Docker/download-history.json` (web) and a **sweep** of `gen.downloadDir` and `baseDir/user_output` for `*.enc` files (CLI-created packs). So packs created by running `gen.sh` from the command line appear in the web Download History.
- **Audit Log:** The API reads `Docker/audit.log` (web). If `gen.auditLogPath` is set (e.g. to a file where the CLI appends JSON lines in the same format), those entries are merged. To have CLI actions in the audit log, the script would need to append JSON lines to that path.
