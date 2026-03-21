# ย้ายทุกอย่างไว้ใน Root เดียว — เปลี่ยน Root หรือ Config แล้วพร้อม Move

เมื่อทุกอย่างอยู่ใต้ **ROOT** เดียว การย้าย user/home = แก้ path เดียว (หรือแค่ config) แล้วรันคำสั่งเดิมได้เลย

---

## 0. สร้างโฟลเดอร์ใน /opt (ถ้า ROOT อยู่ใต้ /opt) — User ต้องมีสิทธิ์ก่อน

ถ้า ROOT ที่จะใช้เป็น **/opt/...** (เช่น `/opt/kafka-usermgmt`) โฟลเดอร์ `/opt` มักเป็นของ root — **ต้องให้ root สร้างโฟลเดอร์แล้ว chown ให้ user ที่รัน (เช่น user2) ก่อน** ถึงจะ copy หรือรัน script ได้

**คำสั่ง (รันด้วย root หรือ sudo):**

```bash
# สร้างโฟลเดอร์แล้วมอบสิทธิ์ให้ user2 (แก้ user2 เป็น user ที่ใช้จริง)
sudo mkdir -p /opt/kafka-usermgmt
sudo chown -R user2:user2 /opt/kafka-usermgmt
```

หลังจากนั้น user2 ถึงจะใช้ path นี้เป็น NEW_ROOT ได้ (copy ไฟล์, แก้ config, รัน container).

**ทางเลือก:** ถ้าไม่อยากใช้ /opt ให้ใช้ path ที่ user นั้นมีสิทธิ์อยู่แล้ว เช่น `/app/user2/kotestkafka`, `/home/user2/kafka-usermgmt` — ไม่ต้องขอ root สร้างให้

---

## 1. โครงสร้างใต้ ROOT (ให้ครบแบบนี้)

ให้โฟลเดอร์ที่ใช้รัน script + Web อยู่ใต้ `ROOT` เดียว เช่น `ROOT=/opt/kafka-usermgmt` หรือ `/app/user3/kotestkafka`:

```
ROOT/
├── confluent-usermanagement.sh   # หรือ gen.sh (ชื่อตาม gen.scriptName ใน config)
├── user_output/                  # script สร้าง .enc ไว้ที่นี่ (สร้างอัตโนมัติถ้าไม่มี)
├── configs/
│   ├── kafka-client.properties
│   └── kafka-client-master.properties
├── kafka_2.13-3.6.1/
│   └── bin/                      # kafka-topics.sh ฯลฯ
├── certs/                        # kafka-truststore.jks (สำหรับดึง topic / test)
├── provisioning.log              # เกิดตอนรัน (ไม่ต้อง copy)
├── .kube/                        # ใส่ kubeconfig ไว้ใน ROOT จะได้ย้ายไปด้วย
│   └── config-both
└── Docker/                       # เก็บ config + ssl ไว้ใน ROOT
    ├── web.config.json
    └── ssl/
        ├── server.key
        └── server.crt
```

- **ถ้า .kube อยู่ที่อื่น (เช่น ~/.kube):** ไม่ต้องย้ายเข้า ROOT แต่ใน config ต้องตั้ง `gen.kubeconfigPath` กับ mount แยก
- **ถ้า SSL อยู่ที่อื่น:** ตั้ง `server.https.keyPath` / `certPath` ใน config และ mount แยก

---

## 2. Path ที่ Config ใช้ (ทั้งหมด — ตั้งใน config หรือให้ derive จาก rootDir)

| ค่าใน config | ความหมาย | ใช้ rootDir แล้วได้จาก |
|--------------|----------|--------------------------|
| **gen.rootDir** | โฟลเดอร์หลัก (ตั้งตัวนี้ตัวเดียว แล้ว path ด้านล่าง derive ให้) | — |
| gen.scriptPath | path ไปที่ shell script | rootDir + `/confluent-usermanagement.sh` |
| gen.baseDir | โฟลเดอร์ทำงานของ script | rootDir |
| gen.downloadDir | โฟลเดอร์ที่ script เขียน .enc | rootDir + `/user_output` |
| gen.kafkaBin | โฟลเดอร์มี kafka-topics.sh | rootDir + `/kafka_2.13-3.6.1/bin` |
| gen.clientConfig | kafka-client.properties | rootDir + `/configs/kafka-client.properties` |
| gen.adminConfig | kafka-client-master.properties | rootDir + `/configs/kafka-client-master.properties` |
| gen.logFile | provisioning.log | rootDir + `/provisioning.log` |
| gen.kubeconfigPath | ไฟล์ kubeconfig | ถ้าใส่ใน ROOT: rootDir + `/.kube/config-both` |
| server.https.keyPath | TLS key (ใน container) | ถ้าใส่ใน ROOT: rootDir + `/Docker/ssl/server.key` (mount จาก host) |
| server.https.certPath | TLS cert (ใน container) | rootDir + `/Docker/ssl/server.crt` (mount จาก host) |

**สรุป:** ใส่ทุกอย่างใน ROOT แล้วตั้งแค่ **gen.rootDir** (+ sites, ocPath, bootstrapServers ฯลฯ ตามเดิม) ก็พอ — path อื่น derive ให้หมด

---

## 3. คำสั่ง Move: ย้ายทุกอย่างเข้า ROOT ใหม่

สมมติเดิมอยู่ที่ `/app/user2/kotestkafka` จะย้ายไป `/opt/kafka-usermgmt` (หรือ user ใหม่ เช่น `/app/user3/kotestkafka`)

**ทางลัด:** ใช้ script ให้สร้าง layout + copy ไฟล์ให้ แล้วแก้แค่ config ตามที่ script แจ้ง:

```bash
NEW_ROOT="/opt/kafka-usermgmt" OLD_ROOT="/app/user2/kotestkafka" ./scripts/move-to-root.sh
```

หรือทำมือตามด้านล่าง:

### 3.1 ตั้งตัวแปร

```bash
# แก้สองบรรทัดนี้ให้ตรงกับคุณ
OLD_ROOT="/app/user2/kotestkafka"
NEW_ROOT="/opt/kafka-usermgmt"
```

### 3.2 สร้างโครงสร้างใต้ NEW_ROOT

```bash
mkdir -p "$NEW_ROOT"/{configs,user_output,.kube,Docker/ssl}
mkdir -p "$NEW_ROOT/kafka_2.13-3.6.1/bin"
```

### 3.3 Copy ไฟล์และโฟลเดอร์จากเดิม

```bash
# script หลัก
cp -a "$OLD_ROOT/confluent-usermanagement.sh" "$NEW_ROOT/" 2>/dev/null || cp -a "$OLD_ROOT/gen.sh" "$NEW_ROOT/confluent-usermanagement.sh"

# configs
cp -a "$OLD_ROOT/configs/"* "$NEW_ROOT/configs/" 2>/dev/null || true

# Kafka bin
cp -a "$OLD_ROOT/kafka_2.13-3.6.1/"* "$NEW_ROOT/kafka_2.13-3.6.1/" 2>/dev/null || true

# certs (truststore สำหรับ Kafka client — ใช้ตอนดึง topic / test)
mkdir -p "$NEW_ROOT/certs"
cp -a "$OLD_ROOT/certs/"* "$NEW_ROOT/certs/" 2>/dev/null || true

# kubeconfig (ถ้าเดิมอยู่ใต้ OLD_ROOT หรือที่อื่น)
cp -a "$OLD_ROOT/.kube/"* "$NEW_ROOT/.kube/" 2>/dev/null || true
# หรือถ้า .kube อยู่ที่ home:
# cp -a /app/user2/.kube/config-both "$NEW_ROOT/.kube/"

# Docker: config + ssl
cp -a "$OLD_ROOT/Docker/web.config.json" "$NEW_ROOT/Docker/" 2>/dev/null || true
cp -a "$OLD_ROOT/Docker/ssl/"* "$NEW_ROOT/Docker/ssl/" 2>/dev/null || true
# หรือถ้า config อยู่ที่ OLD_ROOT โดยตรง:
# cp -a "$OLD_ROOT/web.config.json" "$NEW_ROOT/Docker/"
# cp -a ไฟล์ ssl ไปที่ $NEW_ROOT/Docker/ssl/
```

### 3.3b แก้ path ใน Kafka client config (หลังย้าย)

ไฟล์ใน `configs/kafka-client.properties` และ `configs/kafka-client-master.properties` มี `ssl.truststore.location` — ต้องชี้ไป path **ใหม่** ที่ container เห็น (ใต้ ROOT):

- เปลี่ยน `/app/user2/kotestkafka/certs/...` เป็น `<ROOT>/certs/...` (เช่น `/opt/kafka-usermgmt/certs/kafka-truststore.jks`)
- ให้โฟลเดอร์ `certs/` และไฟล์ truststore อยู่ใต้ ROOT (copy ตาม 3.3 ถ้ายังไม่มี)

ถ้าไม่แก้ จะดึง topic ไม่ได้: `NoSuchFileException: .../certs/kafka-truststore.jks`

**ถ้า .enc ไปอยู่ที่ ROOT ไม่ใช่ใน user_output:** script บน server (confluent-usermanagement.sh) อาจยังเป็นเวอร์ชันเก่า ต้องอัปเดตให้มี `SCRIPT_DIR`, `USER_OUTPUT_DIR` และเขียน `.enc` ไปที่ `USER_OUTPUT_DIR` เหมือนใน `gen.sh` ใน repo นี้ (หรือ copy เนื้อจาก gen.sh ไป merge / แทนที่แล้ว restart container)

### 3.4 แก้ config ให้ใช้แค่ rootDir

แก้ `$NEW_ROOT/Docker/web.config.json` (หรือ path ที่คุณเก็บ config):

- ตั้ง **gen.rootDir** = path ใหม่ (ที่ container จะเห็น ต้องตรงกับที่ mount)
- ลบหรือไม่ใส่ gen.scriptPath, baseDir, downloadDir, kafkaBin, clientConfig, adminConfig, logFile — server จะ derive จาก rootDir ให้
- ถ้าใส่ .kube ใน ROOT: ตั้ง **gen.kubeconfigPath** = `"<ROOT>/.kube/config-both"` (แทน &lt;ROOT&gt; ด้วย path จริง เช่น `/opt/kafka-usermgmt`)
- ถ้าใส่ SSL ใน ROOT: ตั้ง **server.https.keyPath** = `"<ROOT>/Docker/ssl/server.key"` และ **certPath** = `"<ROOT>/Docker/ssl/server.crt"`

ตัวอย่าง config แบบสั้น (เหลือแค่ root + สิ่งที่ไม่ derive):

```json
{
  "_comment": "ทุก path อยู่ใต้ gen.rootDir; เปลี่ยน rootDir อย่างเดียวเมื่อย้าย.",
  "gen": {
    "rootDir": "/opt/kafka-usermgmt",
    "kubeconfigPath": "/opt/kafka-usermgmt/.kube/config-both",
    "ocPath": "/usr/bin",
    "bootstrapServers": "host1:443,host2:443",
    "k8sSecretName": "kafka-server-side-credentials",
    "sites": [
      {"name": "cwdc", "namespace": "esb-prod-cwdc", "ocContext": "cwdc"},
      {"name": "tls2", "namespace": "esb-prod-tls2", "ocContext": "tls2"}
    ]
  },
  "server": {
    "port": 3443,
    "https": {
      "enabled": true,
      "keyPath": "/opt/kafka-usermgmt/Docker/ssl/server.key",
      "certPath": "/opt/kafka-usermgmt/Docker/ssl/server.crt"
    }
  }
}
```

**สำคัญ:** ค่า path ใน config ต้องเป็น **path ที่ process ใน container เห็น** (หลัง mount) — ถ้า mount เป็น `-v /opt/kafka-usermgmt:/opt/kafka-usermgmt` แล้ว rootDir ใน config ก็เป็น `/opt/kafka-usermgmt` ได้เลย

### 3.5 สิทธิ์และ path ที่ container ต้องเห็น

```bash
chmod +x "$NEW_ROOT/confluent-usermanagement.sh"
# ตรวจว่ามีไฟล์ครบ
ls -la "$NEW_ROOT/confluent-usermanagement.sh" "$NEW_ROOT/configs/" "$NEW_ROOT/.kube/" "$NEW_ROOT/Docker/ssl/"
```

---

## 4. คำสั่ง Podman (ใช้ ROOT เดียว)

ตั้ง ROOT แล้วรัน — **เปลี่ยนแค่ ROOT เมื่อย้าย** (เมื่อ .kube และ Docker/ssl อยู่ใต้ ROOT แล้ว และ config ใช้ server.https = ROOT/Docker/ssl/...):

```bash
ROOT="/opt/kafka-usermgmt"   # แก้ตัวนี้เมื่อย้าย

export CONFIG_HOST="$ROOT/Docker/web.config.json"
export BASE_HOST="$ROOT"
export OC_DIR="${OC_DIR:-/usr/bin}"

podman run -d --name kafka-user-web --userns=keep-id --security-opt label=disable -p 443:3443 \
  -v "$CONFIG_HOST:/app/config/web.config.json:ro,z" \
  -v "$BASE_HOST:$BASE_HOST:ro,z" \
  -v "$OC_DIR:/host/usr/bin:ro,z" \
  -e CONFIG_PATH=/app/config/web.config.json \
  confluent-kafka-user-management:latest
```

หมายเหตุ: `-v "$BASE_HOST:$BASE_HOST"` ทำให้ container เห็นทั้ง ROOT (รวม script, configs, user_output, .kube, Docker/ssl) — ไม่ต้อง mount .kube หรือ ssl แยก. ใน config ตั้ง server.https.keyPath/certPath = `"<ROOT>/Docker/ssl/server.key"` และ `"<ROOT>/Docker/ssl/server.crt"` (path ใน container = ROOT)

---

## 5. สรุป: เตรียมตัวก่อนย้าย User

| สิ่งที่ต้องเตรียม | คำสั่ง/การตั้งค่า |
|-------------------|-------------------|
| โครงสร้างใต้ ROOT | ตามหัวข้อ 1 และ 3.2 |
| Copy ไฟล์เข้า ROOT | ตามหัวข้อ 3.3 |
| Config ให้อยู่ใต้ ROOT | เก็บที่ ROOT/Docker/web.config.json และตั้ง **gen.rootDir** (+ kubeconfigPath, server.https ถ้าใช้ path ใน ROOT) ตามหัวข้อ 3.4 |
| รัน container | ใช้ ROOT เดียวในคำสั่ง 4 — เปลี่ยน **ROOT** อย่างเดียวเมื่อย้าย |

เมื่อทำครบแล้ว **การย้าย = เปลี่ยน ROOT (และ gen.rootDir ใน config) แล้วรันคำสั่งเดิม** ไม่ต้องจำ path ย่อยหลายตัว
