# Login / Authorization

เมื่อเปิดใช้ Authorization แล้ว ผู้ใช้ต้อง Login ก่อนจึงจะเข้าใช้งาน Confluent Kafka User Management ได้

**Credentials ไม่อยู่ใน config หรือในเว็บ** — เก็บในไฟล์บน backend เท่านั้น และจัดการผ่าน CLI  

รหัสผ่านที่เพิ่มผ่าน CLI ถูก **hash (scrypt)** เก็บในไฟล์ — อ่านไฟล์แล้วเห็นไม่ตรงๆ ต้องเดาไม่ได้

---

## 1. เปิดใช้ Auth (ใน config ไม่มี user/password)

ใน `web.config.json` ตั้งแค่ **เปิดใช้** และ (ถ้าต้องการ) path ไฟล์เก็บ user:

```json
"server": {
  "port": 3443,
  "https": { "enabled": true, "keyPath": "...", "certPath": "..." },
  "auth": {
    "enabled": true
  }
}
```

ถ้าไม่ระบุ path ระบบจะใช้ไฟล์ `auth-users.json` ในโฟลเดอร์เดียวกับ `web.config.json` (เช่น `webapp/config/auth-users.json`)

ระบุ path เองได้:

```json
"auth": {
  "enabled": true,
  "usersFile": "/opt/kafka-usermgmt/config/auth-users.json"
}
```

---

## 2. จัดการ User ผ่าน CLI เท่านั้น

รันจากโฟลเดอร์ `webapp/` (หรือที่ที่ตั้ง `CONFIG_PATH`):

```bash
# เพิ่ม user (จะถามรหัสผ่าน)
node scripts/auth-users-cli.js add admin

# ใช้รหัสผ่านจาก env (สำหรับ script)
AUTH_NEW_PASSWORD=yourpass node scripts/auth-users-cli.js add operator

# ดูรายชื่อ user (ไม่มีรหัสผ่าน)
node scripts/auth-users-cli.js list

# ลบ user
node scripts/auth-users-cli.js remove operator
```

ไฟล์ที่เก็บ user (เช่น `config/auth-users.json`) ควรอยู่บน server เท่านั้น และ **ไม่ commit ลง git** (เพิ่มใน `.gitignore`)

---

## 3. ความปลอดภัย (Low effort)

- ไฟล์เก็บรหัสเป็น **plain text** — ใช้สิทธิ์ไฟล์จำกัดการอ่าน (เช่น `chmod 600 auth-users.json`) และให้เฉพาะ process ของแอปอ่านได้
- อย่าใส่ path ไฟล์นี้ใน repo ถ้า path ชี้ไปที่ที่เก็บรหัสจริง
- ตัวแปร environment (ทางเลือก):
  - `AUTH_ENABLED=1` — เปิดใช้ auth
  - `AUTH_USERS_FILE=/path/to/auth-users.json` — path ไฟล์ user
  - `SESSION_SECRET=random-string` — ค่า secret สำหรับ session cookie (ควรตั้งใน production)

---

## 4. พฤติกรรม

- ไม่ตั้ง `server.auth.enabled` หรือ `AUTH_ENABLED` → ไม่ถาม Login
- เปิดใช้ auth แต่ยังไม่มี user ในไฟล์ → ไม่มีใคร login ได้ จนกว่าจะใช้ CLI เพิ่ม user
- หลัง Login สำเร็จ → เข้าเมนูหลัก และมีปุ่ม Logout ที่ header

---

## 5. Audit Log และ Download History (ที่เก็บไฟล์)

แอปอ่าน/เขียน **โฟลเดอร์เดียวกับ `auth-users.json`** (หรือ `server.auth.usersFile` ถ้าระบุ):

- **`audit.log`** — บันทึกการกระทำ add-user, remove-user, change-password, test-user, cleanup-acl (ทีละบรรทัด JSON)
- **`download-history.json`** — รายการดาวน์โหลด pack หลัง Add user สำเร็จ

ดังนั้น path จริง = โฟลเดอร์ของ config + ไฟล์เหล่านี้ (เช่น `webapp/config/audit.log` หรือบน server `$ROOT/Docker/audit.log`)

**เมื่อรันด้วย Podman/Docker:** ต้อง mount **ทั้งโฟลเดอร์** ที่มี `web.config.json` และ `auth-users.json` เป็น `/app/config` (ไม่ใช่แค่ mount ไฟล์สองไฟล์) เพื่อให้แอปสร้าง `audit.log` และ `download-history.json` แล้วไฟล์ไปอยู่บน host — ดู `podman-run-config.sh` ว่าใช้ `-v "${ROOT}/Docker:/app/config:z"` แล้วจะเห็น `Docker/audit.log` และ `Docker/download-history.json` บน host
