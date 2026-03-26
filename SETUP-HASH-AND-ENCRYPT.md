# วิธีตั้งค่า Hash (Portal) + Encrypt (OC) ทีละ Step

Build ใหม่รองรับทั้ง plaintext และ hash/encrypt — ตามขั้นตอนด้านล่างจะได้ทั้ง Portal แบบ hash และ OC แบบ encrypt

---

## เกี่ยวกับ Path (ไม่ใช่ Podman)

- **`/path/to/gen-kafka-user`** ในเอกสารนี้ = **placeholder** หมายถึง "โฟลเดอร์ที่คุณเก็บโปรเจกต์ gen-kafka-user ไว้"
- **ไม่ใช่ path ของ Podman** — Podman ใช้แค่ตอนรัน container (เช่น `podman run ...`)
- ตัวอย่าง path จริง:
  - **Windows:** `d:\Project1\gen-kafka-user` → โฟลเดอร์ webapp = `d:\Project1\gen-kafka-user\webapp`
  - **Linux (เครื่อง deploy):** ถ้า copy โปรเจกต์ไปที่ `/opt/kafka-usermgmt` และมีโฟลเดอร์ webapp อยู่ข้างใน = `/opt/kafka-usermgmt/webapp`
  - **Linux (เครื่องอื่น):** เช่น `/home/user2/gen-kafka-user/webapp`
- เวลารันคำสั่ง **แทนที่ `/path/to/gen-kafka-user` ด้วย path จริง** บนเครื่องคุณ

---

## สิ่งที่ต้องมีก่อนเริ่ม

- โปรเจกต์ gen-kafka-user (มี webapp/ + scripts)
- เครื่องที่มี **Node.js** สำหรับรัน script สร้าง hash และ encrypt (ได้ทั้งเครื่อง deploy หรือเครื่อง dev)
- หลังทำครบแล้วต้อง **build image ใหม่** แล้ว deploy + restart container

---

## รัน Script จากใน Docker/Podman Image (ไม่ต้องติด Node บน host)

หลัง **build image ใหม่** (ที่รวม webapp/scripts ใน image แล้ว) — บนเครื่อง deploy **ไม่ต้องมีโฟลเดอร์ webapp หรือ Node** สามารถรัน script ผ่าน container โดย mount โฟลเดอร์ Docker เหมือนตอนรันแอป:

```bash
# ไปที่ ROOT (เช่น /opt/kafka-usermgmt)
cd /opt/kafka-usermgmt

# Portal: list / remove / add (hash จะเขียนลง Docker/auth-users.json ผ่าน mount)
podman run --rm -it \
  -v "$(pwd)/Docker:/app/config:z" \
  -e CONFIG_PATH=/app/config/web.config.json \
  -e AUTH_USERS_FILE=/app/config/auth-users.json \
  confluent-kafka-user-management:latest \
  node scripts/auth-users-cli.js list

podman run --rm -it \
  -v "$(pwd)/Docker:/app/config:z" \
  -e CONFIG_PATH=/app/config/web.config.json \
  -e AUTH_USERS_FILE=/app/config/auth-users.json \
  confluent-kafka-user-management:latest \
  node scripts/auth-users-cli.js remove admin

podman run --rm -it \
  -v "$(pwd)/Docker:/app/config:z" \
  -e CONFIG_PATH=/app/config/web.config.json \
  -e AUTH_USERS_FILE=/app/config/auth-users.json \
  -e AUTH_NEW_PASSWORD="รหัสผ่านที่ต้องการ" \
  confluent-kafka-user-management:latest \
  node scripts/auth-users-cli.js add admin
```

(ถ้าต้องการพิมพ์รหัสเอง ไม่ใส่ `AUTH_NEW_PASSWORD` แล้วรันแบบมี `-it`)

**OC encrypt** (ได้ค่า enc: สำหรับใส่ใน config):

```bash
# สร้าง key บน host ก่อน: openssl rand -hex 32
export OC_CREDENTIALS_KEY="<64 ตัว hex>"
podman run --rm \
  -e OC_CREDENTIALS_KEY="$OC_CREDENTIALS_KEY" \
  confluent-kafka-user-management:latest \
  node scripts/encrypt-oc-password.js "ExamplePassword123!"
```

ได้บรรทัด `enc:xxx` ไปใส่ใน `Docker/web.config.json` แล้วตั้ง `OC_CREDENTIALS_KEY` ตอนรัน container หลักตามเดิม

---

## ส่วนที่ 1: Portal (Web Login) — เก็บแบบ Hash

รหัสผ่านที่เก็บใน `auth-users.json` จะเป็น hash อ่านแล้วเห็นไม่ตรงๆ

### Step 1.1 เปิดไฟล์ auth-users.json บนเครื่อง deploy

- Path: `$ROOT/Docker/auth-users.json` (เช่น `/opt/kafka-usermgmt/Docker/auth-users.json`)
- ดูว่าตอนนี้มี user อะไร (เช่น `admin`) และจดรหัสผ่านที่ใช้ login ไว้ (หรือตั้งรหัสใหม่ที่ต้องการ)

### Step 1.2 รัน CLI บนเครื่องที่มี Node + โปรเจกต์

ไปที่โฟลเดอร์ webapp และชี้ไปที่ config ของเครื่อง deploy (หรือ copy `auth-users.json` มาที่เครื่องนี้ชั่วคราว)

**กรณี config อยู่บนเครื่อง deploy (รันบนเครื่อง deploy):**

```bash
cd /opt/kafka-usermgmt   # หรือ path ที่มี Docker/web.config.json
export CONFIG_PATH=/opt/kafka-usermgmt/Docker/web.config.json
export AUTH_USERS_FILE=/opt/kafka-usermgmt/Docker/auth-users.json

# ลบ user เดิม (ถ้ามี)
node webapp/scripts/auth-users-cli.js remove admin

# เพิ่ม user ใหม่ — รหัสจะถูก hash อัตโนมัติ
node webapp/scripts/auth-users-cli.js add admin
# พิมพ์รหัสผ่านเมื่อถาม แล้ว Enter
```

**กรณีรันจากเครื่อง dev (path ชี้ไปที่ repo):**

```bash
# ไปที่โฟลเดอร์ webapp ในโปรเจกต์ (แทนที่ path ด้านล่างด้วย path จริง เช่น d:\Project1\gen-kafka-user\webapp หรือ /home/you/gen-kafka-user/webapp)
cd <path-ที่เก็บโปรเจกต์>/gen-kafka-user/webapp
# ชี้ไปที่ไฟล์ auth บนเครื่อง deploy (หรือ copy Docker/ จาก deploy มาที่ webapp/config/)
export AUTH_USERS_FILE=<path-ถึง-auth-users.json>

node scripts/auth-users-cli.js remove admin
node scripts/auth-users-cli.js add admin
# พิมพ์รหัสผ่าน
```

### Step 1.3 ตรวจสอบ

เปิด `auth-users.json` ดู — ค่าจะเป็นรูปแบบยาวๆ มี `:` (เช่น `xxxxx:yyyyy`) ไม่ใช่รหัสตรงอีกแล้ว

---

## ส่วนที่ 2: OC (oc login) — เก็บแบบ Encrypt

รหัส OC เก็บใน config เป็น `enc:xxxx` และใช้ key ใน env ถอดรหัสตอนรัน

### Step 2.1 สร้าง Key (ทำครั้งเดียว เก็บไว้ในที่ปลอดภัย)

บนเครื่องที่มี OpenSSL (Linux/Mac/WSL):

```bash
openssl rand -hex 32
```

ได้ข้อความยาว 64 ตัว (hex) — **เก็บค่านี้ไว้** ใช้เป็น `OC_CREDENTIALS_KEY` (อย่าแชร์/commit)

ตัวอย่าง (ไม่ใช้ของนี้จริง):  
`a1b2c3d4e5f6...` (64 ตัว)

### Step 2.2 แปลงรหัส OC เป็นค่า enc:

บนเครื่องที่มี Node + โปรเจกต์:

```bash
# ไปที่โฟลเดอร์ webapp (แทนที่ <path-ที่เก็บโปรเจกต์> ด้วย path จริง เช่น d:\Project1\gen-kafka-user หรือ /opt/kafka-usermgmt)
cd <path-ที่เก็บโปรเจกต์>/gen-kafka-user/webapp

# ตั้ง key ที่สร้างจาก Step 2.1
export OC_CREDENTIALS_KEY="<ใส่ 64 ตัว hex ที่ได้จาก openssl rand -hex 32>"

# แปลงรหัส OC เป็น ciphertext (แทนที่ด้วยรหัสจริงของคุณ — อย่า commit รหัสจริง)
node scripts/encrypt-oc-password.js "ExamplePassword123!"
```

จะได้บรรทัดขึ้นต้นด้วย `enc:` — **copy ทั้งบรรทัด** (เช่น `enc:KEdsTpBw...`)

### Step 2.3 แก้ web.config.json บนเครื่อง deploy

- เปิด `$ROOT/Docker/web.config.json` (เช่น `/opt/kafka-usermgmt/Docker/web.config.json`)
- ใน `gen` หา `ocLoginPassword`
- **เปลี่ยนจาก plaintext เป็นค่า enc:**
  - เดิม: `"ocLoginPassword": "plaintext-or-use-encrypt-script"`
  - ใหม่: `"ocLoginPassword": "enc:xxxx..."` (ใส่ค่าที่ได้จาก Step 2.2)
- **เก็บ `ocLoginUser` ไว้เหมือนเดิม** (user ไม่ต้อง encrypt ก็ได้)
- Save ไฟล์

### Step 2.4 ตั้ง OC_CREDENTIALS_KEY ตอนรัน container

ต้องส่ง key เข้า container ทุกครั้งที่รัน — ใช้วิธีใดวิธีหนึ่ง:

**วิธี A: export ก่อนรันสคริปต์**

```bash
export OC_CREDENTIALS_KEY="<64 ตัว hex ที่สร้างไว้>"
./podman-run-config.sh
```

**วิธี B: แก้ใน podman-run-config.sh**

เปิด `podman-run-config.sh` หาบริเวณที่ comment เรื่อง OC แล้วเพิ่ม (หรือ uncomment):

```bash
export OC_CREDENTIALS_KEY="<64 ตัว hex ที่สร้างไว้>"
```

แล้วรัน `./podman-run-config.sh` ตามปกติ

- **หมายเหตุ:** สคริปต์มีส่ง `OC_CREDENTIALS_KEY` เข้า container อยู่แล้ว ถ้ามีการ export ไว้ใน shell

---

## ส่วนที่ 3: Build + Deploy

### Step 3.1 Build image ใหม่

ที่ root โปรเจกต์ gen-kafka-user (แทนที่ path ด้านล่างด้วย path จริง):

```bash
cd <path-ที่เก็บโปรเจกต์>/gen-kafka-user
podman build -t confluent-kafka-user-management:latest .
# หรือใช้สคริปต์ export ถ้าต้องส่งไปอีกเครื่อง
# ./build-export-image.sh
```

### Step 3.2 Deploy ภาพใหม่

- ถ้ารันบนเครื่องเดียวกัน: หยุด container เดิม แล้วรันใหม่ (ด้วยสคริปต์ที่ตั้ง OC_CREDENTIALS_KEY แล้ว)
- ถ้า deploy ไปอีกเครื่อง: load image ใหม่ แล้วรัน container โดย **ต้องมี OC_CREDENTIALS_KEY** ใน env ตอนรัน (ตาม Step 2.4)

### Step 3.3 ตรวจสอบ

1. **Portal:** เปิดเว็บ → Login ด้วย user (เช่น admin) + รหัสที่ตั้งใน Step 1.2 → ต้องเข้าได้
2. **OC:** ดู log container ควรเห็น `[oc-auto-login] <context> OK (user/password)` ต่อ context ไม่มีข้อความ "ไม่สามารถถอดรหัส"

---

## สรุป Checklist

- [ ] Portal: รัน `auth-users-cli.js remove admin` แล้ว `add admin` (รหัสถูก hash ใน auth-users.json)
- [ ] OC: สร้าง key (`openssl rand -hex 32`) เก็บไว้
- [ ] OC: รัน `encrypt-oc-password.js "รหัสOC"` ได้ค่า `enc:xxx`
- [ ] OC: แก้ web.config.json ใส่ `"ocLoginPassword": "enc:xxx"`
- [ ] OC: ตั้ง `export OC_CREDENTIALS_KEY=...` ก่อนรัน container (หรือใส่ในสคริปต์)
- [ ] Build image ใหม่
- [ ] Deploy + restart container
- [ ] ทดสอบ login Portal และดู log oc-auto-login

---

## ถ้าต้องการกลับเป็น Plaintext

- **Portal:** รัน `auth-users-cli.js remove admin` แล้ว `add admin` แล้วแก้ `auth-users.json` กลับเป็น `"admin": "รหัสตรง"` (ไม่แนะนำ) หรือใช้แค่รหัสตรงในไฟล์ — build ปัจจุบันรองรับทั้ง hash และ plaintext
- **OC:** ใน web.config.json เปลี่ยน `ocLoginPassword` กลับเป็นรหัสตรง (ลบ `enc:`) และไม่ต้องตั้ง OC_CREDENTIALS_KEY
