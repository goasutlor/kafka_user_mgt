# เทสใน Lab ให้ชัวร์ก่อน Deploy

แนวทางให้เทสใน Lab จนมั่นใจแล้วค่อย build/export ไป Deploy จริง — **โหลดไฟล์ .tar ไป Production แค่ครั้งเดียว** หลัง Lab ผ่านครบ

---

## หลักการ

| ระยะ | ทำอะไร | โหลด .tar? |
|------|--------|------------|
| **Lab (เทสบ่อย)** | รัน Web ด้วย **Node ตรงๆ** หรือ **container จาก build ใน Lab** — แก้ code/config แล้วรันใหม่ได้ทันที | ไม่ต้องส่ง .tar |
| **Lab (เทสครบ)** | ใช้ **ทดสอบ API ครบทุกตัว** แล้วใช้ **Checklist** เทสทุกฟีเจอร์จนผ่าน | - |
| **Deploy จริง** | เมื่อ Lab ผ่านครบ → **build + export .tar ครั้งเดียว** → ส่งไป Production → load + run ครั้งเดียว | ครั้งเดียว |

ผลลัพธ์: ใน Lab ไม่ต้องรอโหลด/ส่งไฟล์ใหญ่บ่อย แก้แล้วรันใหม่ได้เร็ว — โหลด .tar ยาวๆ ทำแค่ตอนจะ Deploy จริง

---

## 0) เทสก่อน แล้วค่อยเอาไปแก้ไข / Deploy (ยิง API หรือ Shell Script)

แนวทาง: **เทสให้ครบก่อน** (ยิง API หรือใช้ shell script เช็ค) ว่าได้ครบทุก endpoint แล้ว **ค่อย** build image / แก้ไข / deploy จริง

### วิธีที่ 1: ยิง API ด้วย Node (npm run test:api)

1. **รัน server** (หรือ deploy ชั่วคราวบน Lab):
   ```bash
   cd /path/to/gen-kafka-user/webapp
   npm install --omit=dev
   CONFIG_PATH=config/web.config.json STATIC_DIR=../web-ui-mockup node server/index.js
   ```
   หรือใช้ container ที่รันอยู่แล้วบน Lab

2. **รันเทส API** (จากเครื่องที่เข้าถึง server ได้):
   ```bash
   cd /path/to/gen-kafka-user/webapp
   npm run test:api
   ```
   ถ้า server อยู่คนละเครื่อง:
   ```bash
   BASE_URL=https://10.235.160.31 npm run test:api
   NODE_TLS_REJECT_UNAUTHORIZED=0 BASE_URL=https://10.235.160.31 npm run test:api   # ถ้า HTTPS self-signed
   ```

3. **ดูผล:** จะได้ `[PASS]`/`[FAIL]` ต่อรายการ และสรุป **x/16 passed** (11 smoke + 5 ทุก Function เรียก gen.sh ได้จริง)  
   - **ครบ 16/16** → พร้อม build / แก้ไข / deploy  
   - **มี FAIL** → ดูข้อความ Error/Response แล้วแก้ (image, config, env) แล้วเทสใหม่จนครบ

### วิธีที่ 2: Shell script เช็ค (ใช้ curl — ไม่ต้องมี Node)

จากเครื่องที่เข้าถึง Web ได้ (มีแค่ `curl`):

```bash
cd /path/to/gen-kafka-user
chmod +x scripts/check-deployment.sh
./scripts/check-deployment.sh https://10.235.160.31
```

**ถ้าเปิดด้วย HTTPS** ใช้ `https://<IP>` (หรือ `https://<IP>:443`). สคริปต์จะใช้ `-k` อัตโนมัติเมื่อ URL ขึ้นต้นด้วย https (รองรับ self-signed cert).  
ถ้าเทสบนเครื่องเดียวกับ server อาจใช้ `http://localhost:3000` ได้ถ้ารันแบบ HTTP  
สคริปต์จะยิง API ทุกตัว + **เช็ค gen.sh reachable** + **เช็คทุก Function/Menu** (Add/Test/Remove/Change/Cleanup ว่าแต่ละตัวเรียก gen.sh ได้จริง) แล้วพิมพ์ `[PASS]`/`[FAIL]` และสรุป **x/16 passed**  
ถ้า FAIL จะมีข้อความ Response หรือ Error แนะนำให้แก้ (เช่น ต้องใช้ image ใหม่, แก้ scriptPath) — ครบ 16/16 แล้วค่อย deploy

**ความละเอียดของการเช็ค:** ทุกเมนูใน UI ตรงกับ gen.sh 100% — สคริปต์ตรวจทั้ง 11 รายการ smoke (version, config, topics, users, download path traversal, validation แต่ละ API, cleanup-acl, gen.sh reachable) และอีก 5 รายการว่าแต่ละฟังก์ชัน (Add user, Test user, Remove user, Change password, Cleanup ACL) เรียก gen.sh ได้จริง (ได้ 200 หรือ 500 ที่เป็น "gen.sh exited N" ไม่ใช่ ENOENT/not found)

| เมนูใน UI | API | การเช็คใน check-deployment.sh |
|-----------|-----|------------------------------|
| Add new user | POST /api/add-user | Smoke: validation 400; Function: POST ด้วย body ครบ → 200 หรือ 500 จาก gen.sh |
| Test existing user | POST /api/test-user | Smoke: validation 400; Function: POST ด้วย username/password/topic → 200 หรือ 500 จาก gen.sh |
| Remove user(s) + ACL | POST /api/remove-user | Smoke: validation 400; Function: POST ด้วย users → 200 หรือ 500 จาก gen.sh |
| Change password | POST /api/change-password | Smoke: validation 400; Function: POST ด้วย username/newPassword → 200 หรือ 500 จาก gen.sh |
| Cleanup orphaned ACLs | POST /api/cleanup-acl | Smoke: 200/500 + gen.sh reachable; Function: POST {} → 200 หรือ 500 จาก gen.sh |
| (dropdowns) | GET /api/topics, GET /api/users | Smoke: 200 |
| Download .enc | GET /api/download/:file | Smoke: path traversal 400/404 |

### วิธีที่ 3 (optional): เทส E2E ด้วยข้อมูลจริง (Add user + Remove)

ถ้าอยากให้แน่ใจว่า **Add user / Remove ทำงานจริง 100%** (ไม่ใช่แค่ validation) ให้รันใน Lab ด้วย topic + username ที่มีจริง:

```bash
export TEST_TOPIC=your_topic_ที่มีจริง
export TEST_USER=testuser999
export TEST_PASSPHRASE=secret123
./scripts/check-e2e.sh https://10.235.160.31
```

สคริปต์จะลอง **Add user** แล้ว **Remove user นั้น** — ถ้าผ่านแปลว่า Function Add/Remove ทำงานได้จริง

**หมายเหตุ:** บาง endpoint (GET /api/topics, GET /api/users) อาจได้ **500** ถ้า Kafka/oc ยังไม่พร้อม — รันเทสบน Lab ที่มี Kafka + oc แล้วแก้จนครบ

---

## 1) เทสใน Lab แบบเร็ว (ไม่ต้องโหลด .tar)

### วิธี A: รันด้วย Node ตรงๆ (เร็วที่สุด — แก้ code แล้ว restart ได้ทันที)

บนเครื่อง Lab ที่มี Node 18+, gen.sh, oc, Kafka:

```bash
cd /path/to/gen-kafka-user/webapp
npm install --omit=dev
# แก้ webapp/config/web.config.json ให้ชี้ path ตรงกับ Lab
CONFIG_PATH=config/web.config.json STATIC_DIR=../web-ui-mockup node server/index.js
```

เปิด `http://<Lab-IP>:3000` เทสจาก UI ได้เลย — แก้ code แล้วกด Ctrl+C แล้วรันคำสั่งเดิมใหม่ ไม่ต้อง build image

### วิธี B: รัน container จาก build ใน Lab (สภาพใกล้ Production)

บนเครื่อง Lab ที่มี Docker/Podman:

```bash
cd /path/to/gen-kafka-user
docker build -t confluent-kafka-user-management:latest .
# หรือ podman build -t confluent-kafka-user-management:latest .

# รันด้วย config + mount ตาม INSTALL.md / RUN-AFTER-LOAD.md
docker run -d --name kafka-user-web -p 3443:3443 ...
```

เทสจาก UI ได้ — ถ้าแก้ code ให้ `docker build` ใหม่ใน Lab (ไม่ต้อง export/ส่ง .tar ไปที่อื่น)

---

## 2) Checklist เทสใน Lab (ให้ครบก่อน Deploy)

รันผ่านทีละข้อ แล้วติ๊ก/บันทึกว่าผ่านหรือไม่:

- [ ] **Config** — เปิด `https://<Lab>:port` เห็นหน้า Confluent Kafka User Management
- [ ] **Add user** — ใส่ System, Topic, Username, Passphrase + Confirm → Create → ได้ success (หรือ error จาก gen.sh เช่น topic ไม่มี) **ไม่ใช่** "gen.sh not found" หรือ "spawn bash ENOENT"
- [ ] **Download** — หลัง Add user สำเร็จ มีปุ่ม Download .enc และกดดาวน์โหลดได้
- [ ] **Test user** — ใส่ username, password, topic → Test auth → ได้ผล (OK หรือ error จาก Kafka)
- [ ] **Remove user(s)** — ใส่ username (หรือหลายคนคั่นด้วย comma) → Remove → ได้ success (หรือ error ชัดเจนจาก gen.sh)
- [ ] **Change password** — ใส่ username + new password → Change password → ได้ success
- [ ] **Cleanup ACL** — กด Run cleanup → ได้ success หรือ "No orphaned ACLs"

ถ้าทุกข้อผ่าน แปลว่าใน Lab พร้อมใช้ — ถึงค่อย build และ export .tar ไป Deploy จริง

---

## 3) สคริปต์ Smoke Test (optional — เรียก API จาก command line)

ใช้เทสว่า server ตอบและรับ API ได้ (ไม่ต้องเปิด browser):

```bash
# ตั้ง BASE_URL ตรงกับ Lab (เช่น https://10.235.160.31 หรือ http://Lab-IP:3000)
BASE_URL="https://10.235.160.31"
# ถ้า self-signed cert เพิ่ม -k เพื่อข้ามการตรวจสอบ cert
CURL_OPTS="-k -s"

echo "1. GET /api/config"
curl $CURL_OPTS "$BASE_URL/api/config" | head -c 200
echo ""

echo "2. POST /api/add-user (validation only - expect 400 if no body)"
curl $CURL_OPTS -X POST "$BASE_URL/api/add-user" -H "Content-Type: application/json" -d '{}' | head -c 300
echo ""
```

บันทึกเป็นไฟล์ `scripts/smoke-test.sh` แล้วรันบนเครื่องที่เข้าถึง Lab ได้ — ถ้า (1) ได้ JSON จาก /api/config และ (2) ได้ 400 หรือ error ที่คาดไว้ แปลว่า server ขึ้นและรับ request ได้

---

## 4) เมื่อ Lab ผ่านครบ — Deploy จริง (โหลด .tar แค่ครั้งเดียว)

ก่อน build Docker ควรรันเทสให้ได้ **16/16 passed** ก่อน (ยิง API ด้วย `npm run test:api` หรือ shell script `./scripts/check-deployment.sh <URL>` — ดูหัวข้อ 0 ด้านบน; ถ้าต้องการเทส Add/Remove จริง 100% ใช้ `./scripts/check-e2e.sh` ด้วยข้อมูลจริงใน Lab)

1. **Build image ครั้งเดียว** (บนเครื่องที่ใช้ build เช่น Windows):
   ```powershell
   .\build-export-image.ps1
   ```
   หรือ
   ```bash
   ./build-export-image.sh
   ```
2. **ส่งไฟล์** `confluent-kafka-user-management.tar` ไปยัง Production (Helper Node) แค่ครั้งเดียว
3. **บน Production:** `podman load -i confluent-kafka-user-management.tar` แล้วรัน container ตาม RUN-AFTER-LOAD.md

---

## สรุป

- **Lab:** เทสด้วย Node ตรงๆ หรือ container ที่ build ใน Lab → ใช้ **Checklist** เทสครบทุกฟีเจอร์ → ไม่ต้องโหลด/ส่ง .tar บ่อย
- **Deploy:** เมื่อ Lab ผ่านครบ → build + export .tar **ครั้งเดียว** → ส่งไป Production → load + run **ครั้งเดียว**
- **Smoke test:** ใช้สคริปต์ curl (optional) เพื่อเช็คจาก command line ว่า server ขึ้นและ API รับ request ได้
