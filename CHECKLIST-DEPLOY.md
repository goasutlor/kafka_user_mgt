# Checklist — ย้ายไป /opt/kafka-usermgmt แล้ว Deploy

นอกจาก **Build Docker Image** และ **รัน Script** แล้ว ต้องแก้/เตรียมไฟล์บน **host** ดังนี้

---

## 1. ไฟล์ที่ต้องแก้บน host (หรือให้สคริปต์แก้ให้)

### 1.1 `Docker/web.config.json`  
**ที่อยู่บน host:** `/opt/kafka-usermgmt/Docker/web.config.json`  
(หรือ path ที่คุณใช้เป็น ROOT)

ต้องให้ทุก path ใน `gen` ชี้ไปที่ **/opt/kafka-usermgmt** (หรือ `$ROOT` ที่คุณใช้):

| ค่า | ตัวอย่าง (ROOT=/opt/kafka-usermgmt) |
|-----|-------------------------------------|
| scriptPath | /opt/kafka-usermgmt/gen.sh |
| baseDir | /opt/kafka-usermgmt |
| downloadDir | /opt/kafka-usermgmt/user_output |
| kafkaBin | /opt/kafka-usermgmt/kafka_2.13-3.6.1/bin |
| clientConfig | /opt/kafka-usermgmt/configs/kafka-client.properties |
| adminConfig | /opt/kafka-usermgmt/configs/kafka-client-master.properties |
| logFile | /opt/kafka-usermgmt/provisioning.log |
| kubeconfigPath | /opt/kafka-usermgmt/.kube/config (หรือ `config-both` เฉพาะเมื่อรวมหลาย cluster ในไฟล์เดียว) |
| bootstrapServers | ใส่ host:port จริงของ Kafka (ไม่ใช้ host1/host2) |

- **ถ้ายังไม่ย้าย:** แก้มือหรือ copy จาก repo ไปวางแล้วแก้ path ตามตาราง  
- **ถ้าย้ายจาก path เก่า:** รัน `scripts/migrate-to-opt.sh` จะแก้ path ในไฟล์นี้ให้เป็น NEW_ROOT โดยอัตโนมัติ

---

### 1.2 `configs/*.properties`  
**ที่อยู่บน host:** `/opt/kafka-usermgmt/configs/kafka-client.properties` และ `kafka-client-master.properties`

ต้องให้ path ของ **ssl.truststore** (และ ssl.keystore ถ้ามี) ชี้ไปที่ใต้ ROOT จริง เช่น:

- `ssl.truststore.location=/opt/kafka-usermgmt/certs/kafka-truststore.jks`
- `ssl.truststore.password=...`

- **ถ้าย้ายจาก path เก่า:** รัน `scripts/migrate-to-opt.sh` จะแก้ path ใน configs/*.properties ให้ตรงกับ NEW_ROOT  
- **ถ้าตั้งใหม่:** แก้มือให้ชี้ไปที่โฟลเดอร์ certs จริงใต้ /opt/kafka-usermgmt

---

### 1.3 (ถ้าใช้) `podman-run-config.sh`

- **Default ใช้ ROOT=/opt/kafka-usermgmt อยู่แล้ว** — ไม่ต้องแก้ถ้าใช้ path นี้  
- ถ้าใช้ path อื่น (เช่น `/home/user2/kafka-usermgmt`) ให้แก้บรรทัดบนสุดหรือ export ก่อนรัน:
  ```bash
  export ROOT=/path/to/your/kafka-usermgmt
  ./podman-run-config.sh
  ```

---

## 2. สคริปต์ที่รัน (ลำดับคร่าวๆ)

| ลำดับ | ทำอะไร | หมายเหตุ |
|-------|--------|----------|
| 1 | **ย้ายของไป /opt/kafka-usermgmt** | ถ้ายังอยู่ path เก่า (เช่น /app/user2/kotestkafka) รัน:<br>`sudo scripts/migrate-to-opt.sh /app/user2/kotestkafka`<br>จะ copy ทั้งโฟลเดอร์ + .kube (ถ้ามี) + แก้ path ใน Docker/web.config.json และ configs/*.properties |
| 2 | **Build Docker image** | บนเครื่อง build: `.\build-export-image.ps1` (Windows) หรือ `./build-export-image.sh` (Linux) |
| 3 | **โหลด image บนเครื่องรัน** | `podman load -i confluent-kafka-user-management-<version>.tar` |
| 4 | **รัน container** | `./podman-run-config.sh` (หรือ source แล้ว run_podman_start) |

---

## 3. สรุปสั้น ๆ — ต้องแก้ไฟล์ไหนบ้าง

- **ไม่ย้ายจากที่เก่า (ตั้งใหม่ที่ /opt/kafka-usermgmt เลย)**  
  - แก้ **Docker/web.config.json** ให้ทุก path ใน `gen` = /opt/kafka-usermgmt/...  
  - แก้ **configs/*.properties** ให้ ssl.truststore.location (และที่เกี่ยวข้อง) ชี้ไปที่ /opt/kafka-usermgmt/certs/...

- **ย้ายจาก path เก่า**  
  - รัน **scripts/migrate-to-opt.sh** ให้แล้ว จะแก้ **Docker/web.config.json** และ **configs/*.properties** ให้เอง  
  - หลังรันแล้วควรเปิดดู Docker/web.config.json อีกครั้งว่า path ถูกต้อง (และมี kubeconfigPath, bootstrapServers ตามที่ใช้จริง)

- **podman-run-config.sh**  
  - แก้เฉพาะเมื่อไม่ใช้ ROOT=/opt/kafka-usermgmt (เช่น ใช้ path อื่นเป็น ROOT)

---

## 4. ไฟล์ใน Repo / Image ที่ไม่ต้องแก้บน host

- gen.sh, webapp, web-ui-mockup — มากับ image  
- เอกสาร (INSTALL.md, MIGRATE.md ฯลฯ) — อ่านอ้างอิง ไม่ต้องแก้เพื่อรัน  
- webapp/config/web.config.json ใน repo — เป็นแค่ตัวอย่าง default ใน image; **ค่าจริงที่ใช้รันคือบน host อยู่ที่ ROOT/Docker/web.config.json** (mount เข้า container เป็น /app/config/web.config.json)
