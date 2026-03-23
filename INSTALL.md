# วิธีติดตั้ง — Confluent Kafka User Management (Web)

คู่มือนี้รวมขั้นตอนติดตั้งทั้งหมดตั้งแต่เตรียมเครื่องจนถึงเปิดใช้ได้

**อัปเกรด Docker/Podman image:** การเปลี่ยน image ใหม่ = เปลี่ยน “เครื่องยนต์” แอปใน container เท่านั้น — ไฟล์ config / runtime ที่ **mount จาก host** ไม่ถูก image ทับ (ถ้าไม่ลบโฟลเดอร์บน host และ mount path เดิม) รายละเอียดและข้อยกเว้น: [UPGRADE-AND-PERSISTENCE.md](UPGRADE-AND-PERSISTENCE.md)

---

## เลือกทางรัน (ไม่ต้องติดตั้งเยอะ)

| ทางเลือก | สิ่งที่ต้องมี | วิธีรัน |
|----------|----------------|--------|
| **รัน Node ตรงๆ** | Node 18+ (dependency มีแค่ **express** ตัวเดียว) | **เบื้องต้น:** วาง `run-node.sh` (หรือ `run-node.ps1`) ไว้**โฟลเดอร์เดียวกับ gen.sh** แล้วรันจากโฟลเดอร์นั้น: **Linux/Mac** `./run-node.sh` หรือ **Windows** `.\run-node.ps1` — สคริปต์จะติดตั้ง dependency ให้แล้วรัน server ทันที |
| **Docker image พร้อมใช้** | Docker หรือ Podman (ไม่ต้องติด Node) | บนเครื่อง build: รัน `.\build-export-image.ps1` (Windows) หรือ `./build-export-image.sh` (Linux/Mac) → ได้ไฟล์ **.tar** → นำไปเครื่องปลายทาง → `docker load -i confluent-kafka-user-management.tar` → รัน container ตาม [RUN-AFTER-LOAD.md](RUN-AFTER-LOAD.md) |

**ถ้าเปิด Firewall แค่พอร์ต 443:** ตั้ง server ให้รัน **port 443 + HTTPS** (และ map 443:443 ถ้าใช้ Docker) — ดู [RUN-AFTER-LOAD.md § ถ้าเปิด Firewall แค่ 443](RUN-AFTER-LOAD.md)

**เทสใน Lab ก่อน Deploy:** ดู [TEST-BEFORE-DEPLOY.md](TEST-BEFORE-DEPLOY.md) — เทสด้วย Node ตรงๆ หรือ container แล้วค่อย build/export .tar ไป Production ครั้งเดียว

---

## สิ่งที่ต้องเตรียมบนเครื่องที่จะติดตั้ง (Helper Node / Server)

| รายการ | รายละเอียด |
|--------|-------------|
| **Docker หรือ Podman** | ใช้รัน Web แบบ container (แนะนำ) หรือถ้าไม่ใช้ Docker ต้องมี Node.js 18+ |
| **oc (OpenShift client)** | ต้องมีคำสั่ง `oc` และ kubeconfig ที่เชื่อม OCP ได้ **ครบทุก cluster** ที่ตั้งใน gen.sites |
| **Kafka client** | โฟลเดอร์ที่มี `kafka-topics.sh`, `kafka-acls.sh` (เช่น `kafka_2.13-3.6.1/bin`) |
| **gen.sh** | ไฟล์สคริปต์จากโปรเจกต์นี้ (รองรับ non-interactive แล้ว) วางไว้บนเครื่องให้ path เดียวกับที่ใช้รันมืออยู่ |
| **Configs Kafka** | ไฟล์ `kafka-client.properties`, `kafka-client-master.properties` (path ตามที่ gen.sh ใช้อยู่) |

---

## วิธีที่ 1: ติดตั้งแบบรัน Node โดยตรง (ไม่ใช้ Docker)

เหมาะกับเครื่องที่ติด Node 18+ อยู่แล้ว — **ติดแค่ dependency เดียว (express)** ไม่ต้องลงอะไรเพิ่ม

### รันคำสั่งเดียว (แนะนำ)

**เบื้องต้น:** วาง **run-node.sh ไว้โฟลเดอร์เดียวกับ gen.sh** และให้โฟลเดอร์นั้นมี **webapp/** กับ **web-ui-mockup/** ด้วย (คัดลอกจากโปรเจกต์ไปไว้ข้างๆ gen.sh). ตัวอย่างโครงสร้าง:

```
/opt/kafka-usermgmt/   (หรือโฟลเดอร์ที่อยู่ของ gen.sh — single source of truth)
  gen.sh
  run-node.sh
  webapp/           ← ต้องมี (คัดลอกจากโปรเจกต์)
  web-ui-mockup/    ← ต้องมี (คัดลอกจากโปรเจกต์)
  configs/
  ...
```

จากโฟลเดอร์นั้น:

- **Linux / Mac:** `./run-node.sh`
- **Windows (PowerShell):** `.\run-node.ps1`

สคริปต์จะติดตั้ง `npm install --omit=dev` ให้ครั้งแรก (มีแค่ express) แล้วรัน server ทันที — เปิดเบราว์เซอร์ที่ `http://<IP-เครื่อง>:3000` (หรือ port ใน config)

### ขั้นตอนแบบละเอียด (ถ้าต้องการรันมือเอง)

**1) คัดลอกโปรเจกต์ไปที่เครื่อง**

```bash
scp -r gen-kafka-user user@helper-node:/opt/
```

**2) ปรับ config**

แก้ `webapp/config/web.config.json` ให้ path ตรงกับเครื่องนี้ (scriptPath, baseDir, kafkaBin, ocPath, clientConfig, adminConfig)

**3) รัน**

```bash
cd /opt/gen-kafka-user
./run-node.sh
```

หรือรันใน webapp โดยตรง:

```bash
cd /opt/gen-kafka-user/webapp
npm install --omit=dev
CONFIG_PATH=config/web.config.json STATIC_DIR=../web-ui-mockup node server/index.js
```

**4) เปิดใช้**

เปิดเบราว์เซอร์ที่ `http://<IP-เครื่อง>:3000`

---

## วิธีที่ 2: ติดตั้งแบบ Docker (แนะนำ — ติดแค่ Docker ไม่ต้องติด Node)

เหมาะกับ server ที่มีแค่ Docker/Podman อยากรัน container เดียวแล้วใช้ได้เลย

### ขั้นตอน

**1) เตรียมโฟลเดอร์และ config บนเครื่อง**

สร้างโฟลเดอร์ที่เก็บ gen.sh และ config (แนะนำ `/opt/kafka-usermgmt` เป็น single source of truth) แล้วให้มีอย่างน้อย:

- `gen.sh` (จากโปรเจกต์นี้)
- `configs/kafka-client.properties`, `configs/kafka-client-master.properties`
- โฟลเดอร์ Kafka bin (เช่น `kafka_2.13-3.6.1/bin`)
- ไฟล์ config ของ Web ที่แก้ path แล้ว (เช่น `Docker/web.config.json`)

สร้างหรือแก้ไฟล์ config ของ Web (เช่น `/opt/kafka-usermgmt/Docker/web.config.json`):

```json
{
  "gen": {
    "scriptPath": "/opt/kafka-usermgmt/gen.sh",
    "baseDir": "/opt/kafka-usermgmt",
    "kafkaBin": "/opt/kafka-usermgmt/kafka_2.13-3.6.1/bin",
    "ocPath": "/usr/bin",
    "clientConfig": "/opt/kafka-usermgmt/configs/kafka-client.properties",
    "adminConfig": "/opt/kafka-usermgmt/configs/kafka-client-master.properties",
    "logFile": "/opt/kafka-usermgmt/provisioning.log",
    "k8sSecretName": "kafka-server-side-credentials",
    "kubeconfigPath": "/opt/kafka-usermgmt/.kube/config-both"
  },
  "server": {
    "port": 3000
  }
}
```

แก้ path ด้านบนให้ตรงกับเครื่องคุณ (โดยเฉพาะ `scriptPath`, `baseDir`, `kafkaBin`, `clientConfig`, `adminConfig`)

**2) Build image (ทำครั้งเดียว)**

จากโฟลเดอร์ **gen-kafka-user** (ที่มี Dockerfile, webapp/, web-ui-mockup/):

```bash
cd /path/to/gen-kafka-user
docker build -t confluent-kafka-user-management:latest .
```

หรือใช้ Podman:

```bash
podman build -t confluent-kafka-user-management:latest .
```

**หมายเหตุ:** Build แค่ครั้งเดียว — หลังจากนั้นใช้ image นี้รันได้เรื่อยๆ หรือ export ไปเครื่องอื่นแล้ว import ใช้ได้เลย (ดู [Build แล้ว Export/Import ไปเครื่องอื่น](#build-แล้ว-exportimport-ไปเครื่องอื่น) ด้านล่าง)

**3) Run container**

ตั้งตัวแปรให้ตรงกับ path บนเครื่องคุณ แล้วรัน:

```bash
# แก้ 3 บรรทัดนี้ให้ตรงกับเครื่องคุณ
export CONFIG_HOST=/opt/kafka-usermgmt/Docker/web.config.json
export BASE_HOST=/opt/kafka-usermgmt
export OC_DIR=/usr/bin

docker run -d --name kafka-user-web -p 3000:3000 \
  -v "$CONFIG_HOST:/app/config/web.config.json:ro" \
  -v "$BASE_HOST:$BASE_HOST:ro" \
  -v "$OC_DIR:$OC_DIR:ro" \
  -e CONFIG_PATH=/app/config/web.config.json \
  confluent-kafka-user-management:latest
```

หรือ Podman:

```bash
podman run -d --name kafka-user-web -p 3000:3000 \
  -v "$CONFIG_HOST:/app/config/web.config.json:ro" \
  -v "$BASE_HOST:$BASE_HOST:ro" \
  -v "$OC_DIR:$OC_DIR:ro" \
  -e CONFIG_PATH=/app/config/web.config.json \
  confluent-kafka-user-management:latest
```

- **CONFIG_HOST** = path บนเครื่องไปที่ไฟล์ `web.config.json` ที่แก้แล้ว  
- **BASE_HOST** = โฟลเดอร์ที่มี `gen.sh` และ configs (ต้องตรงกับ `baseDir` ใน config)  
- **OC_DIR** = โฟลเดอร์ที่มีคำสั่ง `oc` (มักเป็น `/usr/bin`)  

สำคัญ: ใน `web.config.json` ค่า `scriptPath` และ `baseDir` ต้องเป็น path **แบบที่ container เห็น** เมื่อใช้ ROOT เดียว (เช่น `/opt/kafka-usermgmt`) จะเป็น path เดียวกับบน host เช่น `/opt/kafka-usermgmt/gen.sh`

**4) เปิดใช้**

เปิดเบราว์เซอร์ที่ `http://<IP-เครื่อง>:3000`

**5) ตรวจสอบ / หยุด / เริ่มใหม่**

```bash
# ดู log
docker logs -f kafka-user-web

# หยุด
docker stop kafka-user-web

# เริ่มใหม่
docker start kafka-user-web
```

---

## Image พร้อมใช้เลย (ไม่ต้อง build บนเครื่องปลายทาง)

ถ้าต้องการ **image พร้อมใช้** — เครื่องที่จะรันมีแค่ Docker + ไฟล์ image ไม่ต้องมี source code หรือ build อะไร:

### ทางที่ 1: รับไฟล์ image จากทีม/เครื่อง build

ถ้ามีคนสร้างไฟล์ **confluent-kafka-user-management.tar** ให้แล้ว:

**บนเครื่องปลายทาง (ที่ต้องการรัน Web):**

1. คัดลอกไฟล์ `confluent-kafka-user-management.tar` มาที่เครื่อง
2. โหลด image เข้า Docker:
   ```bash
   docker load -i confluent-kafka-user-management.tar
   ```
3. เตรียมโฟลเดอร์ที่มี `gen.sh`, configs และไฟล์ `web.config.json` (แก้ path ตรงกับเครื่องนี้)
4. รัน container (คำสั่งเดียวกับวิธีที่ 2 ขั้น 3):
   ```bash
   export CONFIG_HOST=/path/บนเครื่อง/คุณ/web.config.json
   export BASE_HOST=/path/บนเครื่อง/คุณ
   export OC_DIR=/usr/bin

   docker run -d --name kafka-user-web -p 3000:3000 \
     -v "$CONFIG_HOST:/app/config/web.config.json:ro" \
     -v "$BASE_HOST:$BASE_HOST:ro" \
     -v "$OC_DIR:$OC_DIR:ro" \
     -e CONFIG_PATH=/app/config/web.config.json \
     confluent-kafka-user-management:latest
   ```
5. เปิด `http://<IP-เครื่อง>:3000`

**สรุป:** บนเครื่องปลายทาง **ไม่ต้อง build** — แค่ `docker load` แล้ว `docker run` (พร้อม mount config + โฟลเดอร์ gen.sh)

---

### ทางที่ 2: สร้างไฟล์ image เอง (เครื่องที่มี source / Docker)

บนเครื่องที่มีโฟลเดอร์ **gen-kafka-user** และ Docker:

```bash
cd /path/to/gen-kafka-user
chmod +x build-export-image.sh
./build-export-image.sh
```

จะได้ไฟล์ **confluent-kafka-user-management.tar** ในโฟลเดอร์เดียวกัน — นำไฟล์นี้ไปเครื่องปลายทาง แล้วทำตามทางที่ 1 (load + run)

บน Windows (PowerShell) ถ้าไม่มี bash:

```powershell
cd D:\path\to\gen-kafka-user
docker build -t confluent-kafka-user-management:latest .
docker save -o confluent-kafka-user-management.tar confluent-kafka-user-management:latest
```

จะได้ `confluent-kafka-user-management.tar` เช่นกัน

---

## (ถ้าต้องการ) รันแบบ HTTPS

ถ้าต้องการให้เปิดผ่าน `https://` มี 2 แบบ:

**แบบที่ 1 — ใส่ใน config**

ใน `web.config.json` เพิ่มใน `server`:

```json
"server": {
  "port": 3443,
  "https": {
    "enabled": true,
    "keyPath": "/path/to/server.key",
    "certPath": "/path/to/server.crt"
  }
}
```

**แบบที่ 2 — ใช้ environment (รัน Node ตรงๆ)**

```bash
USE_HTTPS=1 SSL_KEY_PATH=/path/to/server.key SSL_CERT_PATH=/path/to/server.crt PORT=3443 node server/index.js
```

จากนั้นเข้า `https://<IP>:3443` (ถ้าใช้ self-signed cert เบราว์เซอร์จะเตือน — ใช้ได้ในเครือข่ายภายใน หรือใช้ reverse proxy กับ cert จริง)

---

## ตรวจสอบว่าติดตั้งสำเร็จ

1. เปิด `http://<IP>:3000` แล้วเห็นหน้า Confluent Kafka User Management  
2. ลอง **Add new user** ใส่ Client System Name, Topic, Username, Passphrase + Confirm แล้วกด Create — ควรได้ผลหรือ error จาก gen.sh (เช่น topic ไม่มี, oc ไม่เชื่อม) ไม่ใช่ error ว่าไม่เจอ gen.sh  
3. ถ้า Add user สำเร็จ ควรมีปุ่ม Download และข้อความวิธี decrypt/unpack  

---

## แก้ปัญหาเบื้องต้น

| อาการ | สาเหตุที่เป็นไปได้ | วิธีเช็ค/แก้ |
|--------|----------------------|----------------|
| เปิดเว็บไม่ขึ้น | port ถูกปิดหรือไม่ bind | ตรวจ firewall, รัน `curl http://localhost:3000` บนเครื่อง server |
| กด Create แล้ว error "gen.sh not found" | scriptPath ใน config ผิด หรือ (Docker) path ใน container ไม่ตรง | แก้ `scriptPath` ใน web.config.json ให้ชี้ไปที่ path ที่มี gen.sh จริง (ใน Docker ต้องเป็น path ที่ mount เข้าไป) |
| Add New User ทำไม่ได้จริง (spawn bash ENOENT / exited 1 ฯลฯ) | ดูรายการใน [ADD-USER-TROUBLESHOOT.md](ADD-USER-TROUBLESHOOT.md) | ไล่ตามอาการ: image ต้องมี bash+jq, scriptPath ต้องถูก, รัน script ด้วยมือดู error จริง |
| gen.sh รันแล้ว error (topic not found, oc failed ฯลฯ) | ปัญหาที่ environment (topic, oc, secret) | รัน gen.sh ด้วยมือในโฟลเดอร์นั้นด้วย env เดียวกัน แล้วดู error |
| ดาวน์โหลดไฟล์ .enc ไม่ได้ | ไฟล์อยู่ที่โฟลเดอร์ที่ gen.sh รัน (cwd) แต่ server อ่านคนละที่ | ใน Docker ต้อง mount โฟลเดอร์เดียวกับที่ gen.sh เขียนไฟล์ (BASE_HOST) แล้ว scriptPath/baseDir ต้องชี้ไปที่ path นั้น |
| อยากได้ UX แบบ Shell (ทีละ Step) | Web ออกแบบให้กรอกทั้งหมดทีเดียวแล้วเรียก gen.sh แบบ non-interactive | ดู [DEPLOY-WEB.md § 5.1](DEPLOY-WEB.md) — การทำแบบ interactive ทีละ Step บน Web ต้อง dev ใหม่ |

---

## สรุปลำดับติดตั้ง (แบบ Docker)

1. เตรียมเครื่อง: Docker, oc, Kafka bin, gen.sh, configs  
2. แก้ `web.config.json` ให้ path ตรงกับเครื่อง  
3. Build: `docker build -t confluent-kafka-user-management:latest .` หรือใช้ **image พร้อมใช้:** รัน `./build-export-image.sh` แล้วนำไฟล์ `.tar` ไปเครื่องปลายทาง → `docker load -i confluent-kafka-user-management.tar`  
4. Run: mount config + โฟลเดอร์ gen.sh + โฟลเดอร์ oc แล้ว map port 3000  
5. เปิด `http://<IP>:3000` และทดสอบ Add user  

รายละเอียด API, Feature parity, Performance และ Security testing ดูใน [DEPLOY-WEB.md](DEPLOY-WEB.md) และ [SECURITY-TESTING.md](SECURITY-TESTING.md)
