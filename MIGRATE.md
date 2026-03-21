# Backup & Migrate — ย้าย Script และ Web Config ไปเครื่องใหม่

เอกสารนี้สรุปขั้นตอนการกวาด (Backup) ข้อมูลจากเครื่องต้นทาง และ Restore ที่เครื่องใหม่ รวมถึงการ map ชื่อไฟล์ระหว่าง Repo กับเครื่องจริง

---

## 1. การ map ชื่อไฟล์ (Repo vs เครื่องจริง)

| ใน Repo (gen-kafka-user)     | บนเครื่องจริง (kafka-usermgmt)     |
|------------------------------|-------------------------------------|
| `gen.sh`                     | `confluent-usermanagement.sh`       |
| `podman-run-config.sh`       | `podman_runconfig.sh`               |

Config หลักของ Kafka ที่ใช้กับ script/Web คือ **kafka-client-master.properties** (ในโฟลเดอร์ `configs/`)

---

## 2. โครงสร้างบนเครื่องต้นทาง (ตาม clarify_folder.txt)

```
kafka-usermgmt/
├── confluent-usermanagement.sh    # script หลัก
├── podman_runconfig.sh            # รัน Podman container
├── certs/
│   ├── ca-bundle.crt
│   └── kafka-truststore.jks
├── configs/
│   ├── kafka-client-2.properties
│   ├── kafka-client-master.properties   # ใช้เป็นหลัก
│   └── kafka-client.properties
├── Docker/
│   ├── web.config.json
│   ├── auth-users.json
│   ├── audit.log
│   ├── download-history.json
│   └── ssl/
│       ├── server.crt
│       └── server.key
├── kafka_2.13-3.6.1/             # (optional) Kafka distro — ใหญ่ ~100MB+
├── user_output/                  # *.enc ที่ generate ไว้
├── *.enc                         # บางไฟล์อาจอยู่ที่ root
└── .kube/                        # kubeconfig สำหรับ OC (backup แยกหรือรวมตามนโยบาย)
```

---

## 2.5 Seamless migrate ไป /opt/kafka-usermgmt (บนเครื่องเดิม)

ถ้าตอนนี้รันอยู่ที่ path อื่น (เช่น `/app/user2/kotestkafka`) และอยากย้ายทุกอย่างมาไว้ที่ `/opt/kafka-usermgmt` บนเครื่องเดียวกัน เพื่อให้ backup/restore ไปเครื่องใหม่ทำได้ง่าย (ทุกอย่างอยู่ใต้ root เดียว):

### ใช้สคริปต์ migrate-to-opt.sh

```bash
# รันจากที่ไหนก็ได้ (แนะนำใช้ root เพื่อ chown ได้)
sudo /path/to/gen-kafka-user/scripts/migrate-to-opt.sh /app/user2/kotestkafka
```

- **Argument แรก** = path ปัจจุบันของ kafka-usermgmt (default: `/app/user2/kotestkafka`)
- **ปลายทาง** = `/opt/kafka-usermgmt` เสมอ (override ด้วย env `MIGRATE_NEW_ROOT` ได้)
- สคริปต์จะ: copy ทั้งโฟลเดอร์ไป `/opt/kafka-usermgmt`, copy `.kube` จาก `/app/user2/.kube` มาที่ `/opt/kafka-usermgmt/.kube` ถ้ามี, แก้ path ใน `Docker/web.config.json` ให้ชี้ไป `/opt/kafka-usermgmt` ทั้งหมด

**ตั้ง chown หลังย้าย (ถ้ารันด้วย root):**

```bash
sudo MIGRATE_OWNER=user2:user1 ./migrate-to-opt.sh /app/user2/kotestkafka
```

หลังรันเสร็จ:
1. หยุด container เดิม: `podman stop kafka-user-web; podman rm kafka-user-web`
2. รันจาก path ใหม่: `export ROOT=/opt/kafka-usermgmt && cd $ROOT && ./podman_runconfig.sh`
3. ลบ path เก่าถ้าไม่ใช้แล้ว: `rm -rf /app/user2/kotestkafka`

### ทำเอง (manual) แทนสคริปต์

- Copy ทั้งโฟลเดอร์จาก path เก่าไป `/opt/kafka-usermgmt`
- Copy `/app/user2/.kube` ไป `/opt/kafka-usermgmt/.kube` ถ้าใช้
- แก้ `Docker/web.config.json`: เปลี่ยนทุก path ให้เป็น `/opt/kafka-usermgmt` (รวม `kubeconfigPath` เป็น `/opt/kafka-usermgmt/.kube/config-both`)
- ใช้ **webapp/config/web.config.opt-kafka-usermgmt.json** ใน repo เป็นตัวอย่าง path ที่ถูกต้อง

เมื่อทุกอย่างอยู่ใต้ `/opt/kafka-usermgmt` แล้ว ให้ทำ backup ตามหัวข้อ 3 เพื่อย้ายไปเครื่องใหม่ได้ทันที

---

## 3. ขั้นตอน Backup (บนเครื่องต้นทาง)

### 3.1 รันสคริปต์ Backup

บนเครื่องที่รันอยู่ตอนนี้ (เช่น PKAFKAW401G):

```bash
cd /opt/kafka-usermgmt
# หรือไปที่โฟลเดอร์ที่มี confluent-usermanagement.sh, podman_runconfig.sh, Docker/, configs/

# ใช้ script จาก repo (copy backup-for-migrate.sh มาที่นี่ก่อน) หรือรันจาก repo:
/path/to/gen-kafka-user/scripts/backup-for-migrate.sh /opt/kafka-usermgmt
```

จะได้ไฟล์ `kafka-usermgmt-migrate-YYYYMMDD-HHMM.tar.gz` ใน current directory

**รวม Kafka distro ด้วย (ถ้าเครื่องใหม่ยังไม่มี):**

```bash
INCLUDE_KAFKA_DIST=1 ./backup-for-migrate.sh /opt/kafka-usermgmt
```

**รวม .kube (kubeconfig สำหรับ ocAutoLogin):**

```bash
INCLUDE_KUBE=1 ./backup-for-migrate.sh /opt/kafka-usermgmt
```

### 3.2 สิ่งที่ Backup ไม่รวม (ทำเองถ้าต้องการ)

- **.kube/** — ถ้าใช้ ocAutoLogin ใช้ `INCLUDE_KUBE=1` ตอน backup ได้ หรือ copy โฟลเดอร์ `.kube` ไปเครื่องใหม่เอง (มี credential ใช้ด้วยความระมัดระวัง)
- **Docker image** — ต้อง build หรือ copy ไฟล์ `.tar` ของ image ไปเครื่องใหม่แยก (เช่น `confluent-kafka-user-management-1.0.45.tar`)

### 3.3 ถ้าบนเครื่องต้นทางใช้ชื่อจาก Repo (gen.sh, podman-run-config.sh)

สคริปต์ backup จะ copy เป็นชื่อที่เครื่องใหม่ใช้:

- `gen.sh` → ใส่ใน tarball เป็น `confluent-usermanagement.sh`
- `podman-run-config.sh` → ใส่เป็น `podman_runconfig.sh`

---

## 4. ขั้นตอน Restore (บนเครื่องใหม่)

**ควรรันด้วย root** เพื่อให้สคริปต์ chown ไฟล์ให้ user/group ใหม่ได้ (เครื่องใหม่อาจใช้ user ไม่เหมือนเครื่องเก่า)

### 4.1 Copy ไฟล์ไปเครื่องใหม่

- Copy `kafka-usermgmt-migrate-YYYYMMDD-HHMM.tar.gz` ไปเครื่องใหม่
- (ถ้ามี) Copy ไฟล์ image `confluent-kafka-user-management-*.tar`
- (ถ้าใช้ ocAutoLogin) Copy โฟลเดอร์ `.kube` ไปที่เดียวกันเทียบกับ ROOT

### 4.2 รัน Restore (โหมด Interactive — แนะนำ)

```bash
sudo ./restore-migrate.sh
```

สคริปต์จะถามทีละขั้น:

1. **Path to backup file** — ใส่ path ไฟล์ .tar.gz
2. **Target parent directory** — โฟลเดอร์ที่จะได้ `kafka-usermgmt` อยู่ข้างใน (default: `/opt` → ได้ `/opt/kafka-usermgmt`)
3. **Owner user** — user ที่จะเป็นเจ้าของไฟล์บนเครื่องใหม่ (เช่น `user2`)
4. **Owner group** — group ที่จะเป็นเจ้าของไฟล์ (เช่น `user1` หรือใช้ชื่อเดียวกับ user)

จากนั้นสคริปต์จะแตก tarball, ตั้ง execute ให้ `*.sh`, และ **chown -R user:group** ให้ทั้งโฟลเดอร์ที่ restore

### 4.3 รัน Restore (โหมดกำหนดเอง ไม่ถาม)

```bash
# แตกไปที่ /opt (ได้ /opt/kafka-usermgmt), หลังแตกแล้ว chown เอง
sudo ./restore-migrate.sh ./kafka-usermgmt-migrate-YYYYMMDD-HHMM.tar.gz /opt

# กำหนด user/group ผ่าน env (ยังถาม target ถ้าไม่ส่ง argument ที่สอง)
sudo RESTORE_OWNER_USER=user2 RESTORE_OWNER_GROUP=user1 ./restore-migrate.sh ./backup.tar.gz /opt

# ไม่ถามเลย (ใช้ default /opt และต้องตั้ง RESTORE_OWNER_* ไว้)
sudo RESTORE_NONINTERACTIVE=1 RESTORE_OWNER_USER=user2 RESTORE_OWNER_GROUP=user1 ./restore-migrate.sh ./backup.tar.gz /opt
```

### 4.4 แก้ path / config บนเครื่องใหม่

1. แก้ **web.config.json** (ใน `Docker/`) ถ้า path หรือ host เปลี่ยน:
   - `gen.rootDir` — ชี้ไปที่โฟลเดอร์หลักบนเครื่องใหม่ (เช่น `/opt/kafka-usermgmt`)
   - `gen.kubeconfigPath` — path ของ kubeconfig ใน container (เช่น `/app/user2/.kube/config-both`)
   - `gen.ocLoginServers` — URL API ของ OCP ฯลฯ

2. แก้ **podman_runconfig.sh** (ตัวแปร `ROOT`) ถ้าไม่ใช้ `/opt/kafka-usermgmt`:

   ```bash
   export ROOT="${ROOT:-/opt/kafka-usermgmt}"
   ```

3. วาง **.kube** ให้ตรงกับที่ mount ใน podman_runconfig (เช่น `ROOT/.kube` → `-v "$KUBE_DIR:/app/user2/.kube:z"`)

### 4.5 Load Image และ Start Container

```bash
cd /opt/kafka-usermgmt
podman load -i confluent-kafka-user-management-1.0.45.tar   # ใช้ชื่อไฟล์ image ที่ copy มา
./podman_runconfig.sh
```

---

## 5. สรุป Checklist

| ขั้นตอน | ต้นทาง | ปลายทาง |
|--------|--------|----------|
| Backup | รัน `backup-for-migrate.sh` ได้ไฟล์ .tar.gz | — |
| Copy | — | Copy .tar.gz + image .tar (+ .kube ถ้าต้องการ) |
| Restore | — | รัน `restore-migrate.sh` แตกไป TARGET_ROOT |
| แก้ config | — | แก้ web.config.json, ROOT ใน podman_runconfig.sh |
| .kube | — | วาง .kube ให้ตรงกับ KUBE_DIR |
| Start | — | podman load แล้ว ./podman_runconfig.sh |

---

## 6. ไฟล์ใน Repo ที่เกี่ยวข้อง

- **scripts/migrate-to-opt.sh** — ย้ายทุกอย่างจาก path เก่า (เช่น /app/user2/kotestkafka) ไป /opt/kafka-usermgmt บนเครื่องเดียวกัน (seamless)
- **scripts/backup-for-migrate.sh** — รันบนเครื่องต้นทาง เพื่อสร้าง tarball สำหรับ migrate
- **scripts/restore-migrate.sh** — รันบนเครื่องใหม่ เพื่อแตก tarball และตั้ง permission
- **webapp/config/web.config.opt-kafka-usermgmt.json** — ตัวอย่าง web.config เมื่อรันทั้งหมดใต้ /opt/kafka-usermgmt
- **clarify_folder.txt** — รายการโฟลเดอร์/ไฟล์บนเครื่องจริง (อ้างอิงโครงสร้าง)
