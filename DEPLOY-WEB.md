# Deploy Web (Confluent Kafka User Management) บน Helper Node

**วิธีติดตั้งแบบ step-by-step:** ดู **[INSTALL.md](INSTALL.md)** — รวมวิธีรัน Node โดยตรงและวิธี Docker พร้อมแก้ปัญหาเบื้องต้น

---

## สิ่งที่ต้องมีบน Helper Node

- Docker หรือ Podman
- `oc` (OpenShift client) และ kubeconfig
- Kafka client (kafka_2.13-3.6.1/bin หรือ path ที่ใช้กับ gen.sh)
- ไฟล์ **gen.sh** (ตัวเดิมที่รองรับ non-interactive แล้ว)

---

## 1. ปรับ web.config.json

คัดลอก `webapp/config/web.config.json` ไปที่เครื่อง Helper (หรือแก้ใน repo แล้ว build image ใหม่) แล้วแก้ path ให้ตรงกับเครื่อง:

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
    "k8sSecretName": "kafka-server-side-credentials"
  },
  "server": {
    "port": 3000
  }
}
```

- **scriptPath** — path เต็มไปที่ gen.sh  
- **baseDir** — โฟลเดอร์หลัก (ที่อยู่ของ configs, pack output)  
- **kafkaBin** — โฟลเดอร์ที่มี kafka-topics.sh, kafka-acls.sh  
- **ocPath** — โฟลเดอร์ที่มีคำสั่ง `oc` (จะถูกใส่ใน PATH ตอนรัน gen.sh)

---

## 2. Build image

จากโฟลเดอร์ **gen-kafka-user** (ที่มี Dockerfile, webapp/, web-ui-mockup/):

```bash
docker build -t confluent-kafka-user-management:latest .
# หรือ
podman build -t confluent-kafka-user-management:latest .
```

---

## 3. Run (mount config + paths ที่ gen.sh ใช้)

ให้ container เห็น path เดียวกับที่ gen.sh ใช้ (มี gen.sh, Kafka bin, configs, oc):

```bash
# ตัวอย่าง: ทุกอย่างอยู่ใต้ /opt/kafka-usermgmt (single source of truth)
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

หรือใช้ Podman:

```bash
podman run -d --name kafka-user-web -p 3000:3000 \
  -v "$CONFIG_HOST:/app/config/web.config.json:ro" \
  -v "$BASE_HOST:$BASE_HOST:ro" \
  -v "$OC_DIR:$OC_DIR:ro" \
  -e CONFIG_PATH=/app/config/web.config.json \
  confluent-kafka-user-management:latest
```

- **scriptPath** ใน web.config ต้องชี้ไปที่ path ที่ container เห็น เช่น `/opt/kafka-usermgmt/gen.sh` เมื่อใช้ ROOT เดียว

เปิดเบราว์เซอร์ที่ `http://<Helper-Node-IP>:3000`

---

## 4. ทดสอบ Unit Test และ Security ก่อน build

บนเครื่องที่พัฒนา (มี Node 18+):

```bash
cd webapp
npm install
npm test
```

มี Unit Test และ Security/Vulnerability tests หลายรอบ (รวม 30 tests): validation add-user (passphrase/confirm), parsePack/buildDecryptInstructions, download path traversal, filename edge cases, method/route, body size limit

**หมายเหตุ:** การทดสอบเหล่านี้เป็น security-focused unit tests ในระดับ development **ไม่เทียบเท่า Pentest หรือ VA อย่างเป็นทางการ** — มาตรฐานและแนวทางสำหรับ Pentest/VA ดูใน [SECURITY-TESTING.md](SECURITY-TESTING.md)

ผ่านแล้วค่อย build Docker ตามขั้นตอนด้านบน

---

## 5. Feature parity: gen.sh vs Web

ฟีเจอร์หลักของ gen.sh ที่ **Web/API รองรับครบ**:

| โหมด | รายการ | Web/API |
|------|--------|---------|
| 1 | Add new user (system, topic, username, ACL read/all) | ✅ POST /api/add-user |
| 2 | Test user (auth ทุก cluster ที่ตั้งใน config + list ACL) | ✅ POST /api/test-user |
| 3 | Remove user(s) + ACL | ✅ POST /api/remove-user |
| 3 | Change password | ✅ POST /api/change-password |
| 3 | Cleanup orphaned ACLs | ✅ POST /api/cleanup-acl |

ฟีเจอร์ที่ **มีแค่ใน gen.sh แบบ interactive** (ยังไม่เปิดบน Web):

- **Test user:** หลัง auth แล้วเลือก [1] Describe topic หรือ [2] Consume 5 messages — โหมด non-interactive ทำแค่ auth + list ACL แล้วจบ
- **Change password:** หลังเปลี่ยนรหัสแล้วถาม "Add Topic + ACL for this user?" — โหมด non-interactive ทำแค่เปลี่ยนรหัส ไม่มีขั้นตอนเพิ่ม topic+ACL

ถ้าต้องการให้ Web รองรับ "Change password แล้วเพิ่ม Topic+ACL" หรือ "Test แล้ว describe/consume" ต้องเพิ่ม env ใน gen.sh (เช่น GEN_ADD_TOPIC_ACL=1, GEN_TOPIC_NAME, GEN_ACL สำหรับ change-password) และเพิ่ม API/UI ตามนั้น

---

## 5.0 Shell แบบ Step-by-step (gen-wizard.sh)

นอกจาก **gen.sh** (เมนูแบบเดิม) แล้ว มีสคริปต์ **gen-wizard.sh** สำหรับ Add new user แบบทีละขั้น พร้อม validate ระหว่างทาง:

- **Step 1:** Client System Name + Topic (โชว์ list topics, validate ว่า topic มีจริง)
- **Step 2:** Username (โชว์ list users ที่มีอยู่, validate ไม่ซ้ำ)
- **Step 3:** ACL (Read / All)
- **Step 4:** Passphrase + confirm
- **Step 5:** Execute — เรียก gen.sh ด้วยค่าที่กรอก

รันบน Helper Node ในโฟลเดอร์เดียวกับ gen.sh (ใช้ config ตัวเดียวกันผ่าน env):  
`./gen-wizard.sh`  
**gen.sh เก็บไว้ไม่แก้** — wizard เป็นตัวเรียก gen.sh ตอนขั้น Execute เท่านั้น

---

## 5.1 User Experience: Web vs Interactive Shell

| | **Web** | **Interactive Shell (gen.sh)** |
|--|--------|--------------------------------|
| **การใช้งาน** | กรอกฟอร์มทั้งหมด (System, Topic, Username, Passphrase ฯลฯ) แล้วกด Submit ครั้งเดียว → รอผลลัพธ์ | รัน `./gen.sh` แล้วตอบทีละขั้น (เมนู → ใส่ค่าตามที่ script ถาม) |
| **ผลลัพธ์** | ได้ response เดียว (success + ลิงก์ดาวน์โหลด หรือ error) | เห็น output ทีละขั้น จนจบ flow |

**เหตุผลที่ Web ทำแบบ “กรอกทีเดียวแล้วรอ” ไม่ใช่แบบ “ทีละ Step เหมือน Shell”:**

- Web ทำงานโดย **Backend เรียก gen.sh แบบ non-interactive** — ส่งค่าทั้งหมดผ่าน environment (GEN_*, ฯลฯ) แล้วรัน script **ครั้งเดียว** ไม่มีการส่งค่าทีละขั้นกลับไปกลับมา
- ไม่มี “session” หรือ “conversation” กับ script: HTTP request หนึ่งครั้ง = เรียก `bash gen.sh` หนึ่งครั้ง แล้วรอจนจบ

**ถ้าอยากได้ UX แบบ Step-by-step (wizard) บน Web:**  
ต้องออกแบบและพัฒนาใหม่ เช่น

- แยก API เป็นหลายขั้น (ขั้น 1 ใส่ system/topic → ขั้น 2 ใส่ user/permission → ขั้น 3 ใส่ passphrase → ขั้น 4 execute) และอาจต้องให้ gen.sh รองรับการรับค่าทีละส่วน หรือ
- มี backend ที่เก็บ state ระหว่างขั้น และค่อยเรียก logic (หรือ gen.sh) เมื่อครบทุก input

สรุป: **ที่ทำอยู่คือ “กรอกทั้งหมดทีเดียวแล้วรอ result” โดยออกแบบให้เรียก Shell แบบ non-interactive ได้ตรงกับ gen.sh ที่มีอยู่；การทำแบบ Interactive ทีละ Step บน Web ต้อง dev ใหม่ทั้งหมด**

---

## 6. API ที่ใช้กับ Web

| Method + Path | Body | ใช้กับ |
|---------------|------|--------|
| GET /api/version | — | เวอร์ชันของ image/API (ใช้ดูว่าเป็น image ใหม่หรือเก่า) |
| GET /api/topics | — | รายการ topic (เรียก kafka-topics.sh --list). **ให้ได้:** ต้อง mount โฟลเดอร์ที่มี kafkaBin + adminConfig; bootstrap อ่านจาก admin config หรือตั้ง gen.bootstrapServers ใน config |
| GET /api/users | — | รายการ user จาก plain-users.json ใน OCP ทุก site (เรียก oc get secret ต่อ site). **ให้ได้:** ต้องมี oc ใน PATH (ocPath), gen.kubeconfigPath และ gen.sites (หรือ legacy gen.namespace + gen.ocContext) ให้ครบทุก cluster ที่ใช้ |
| POST /api/add-user | systemName, topic, username, acl?, **passphrase** | Add new user (ต้องใส่ passphrase เพื่อ encrypt pack) |
| GET /api/download/:filename | — | ดาวน์โหลดไฟล์ .enc ที่ gen.sh สร้าง (filename จาก response add-user) |
| POST /api/test-user | username, password, topic | Test existing user |
| POST /api/remove-user | users (array หรือ comma-separated) | ลบ user + ACL |
| POST /api/change-password | username, newPassword | เปลี่ยนรหัส |
| POST /api/cleanup-acl | (ไม่ต้องส่ง body) | ลบ ACL ค้าง |

หลัง Add user สำเร็จ API จะคืน `packFile`, `downloadPath`, `decryptInstructions` (ข้อความวิธี decrypt/unpack เหมือนที่ gen.sh แสดง 100%)

---

## 7. Performance (Docker)

- **Image เดียว:** Front (static) + Back (Node) อยู่ใน image เดียว ไม่ต้อง install อะไรเพิ่มบน Server นอกจาก Docker/Podman
- **Multi-stage build:** ติดตั้งเฉพาะ production dependencies ลดขนาด image
- **NODE_OPTIONS:** จำกัด heap 128MB เพื่อลด memory
- **Static cache:** ตั้ง maxAge 1 ชม. สำหรับ static files

---

## 8. รันแบบ HTTPS

ถ้าต้องการให้ server รัน HTTPS (รับเรียกเป็น https://) มี 2 วิธี:

**วิธีที่ 1: ใช้ config**

ใน `web.config.json` เพิ่ม `server.https`:

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

**วิธีที่ 2: ใช้ environment**

```bash
export USE_HTTPS=1
export SSL_KEY_PATH=/path/to/server.key
export SSL_CERT_PATH=/path/to/server.crt
export PORT=3443
node server/index.js
```

จากนั้นเปิดเบราว์เซอร์ที่ `https://<host>:3443` (ถ้าใช้ self-signed cert เบราว์เซอร์จะเตือน — ใช้ได้ในเครือข่ายภายใน หรือใช้ reverse proxy กับ cert จริง)
