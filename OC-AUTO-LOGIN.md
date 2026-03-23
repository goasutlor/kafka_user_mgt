# Auto OC Login — ไม่ต้อง SSH เข้า VM เพื่อ oc login ก่อน

เมื่อเปิดใช้ **ocAutoLogin** Web จะรัน `oc login` ให้อัตโนมัติทุกครั้งที่ server เริ่มทำงาน (หลัง restart container) จึงไม่ต้อง SSH เข้า VM เพื่อรัน `oc login` ไว้ก่อน

---

## 1. ตั้งค่าใน web.config.json

ใน `gen` เพิ่ม (หรือแก้) ดังนี้:

```json
"gen": {
  ...
  "kubeconfigPath": "/opt/kafka-usermgmt/.kube/config",
  "ocAutoLogin": true,
  "ocLoginServers": {
    "cwdc": "https://api.cwdc.your-domain.com:6443",
    "tls2": "https://api.tls2.your-domain.com:6443"
  },
  ...
}
```

- **ocAutoLogin**: `true` = เปิดใช้ auto login
- **ocLoginServers**: object แมป **ชื่อ context** (ตรงกับใน gen.sites) → **URL ของ OpenShift API server** ของ cluster นั้น

---

## 2. ฝัง User/Password ใน config (ทำครั้งเดียวแล้ว Auto เอง)

ไม่ต้องไปเอา token — ใส่ **user + password** ไว้ใน config เดียวกับ ocLoginServers แล้วแอปจะรัน `oc login -u ... -p ...` ให้เองทุกครั้งที่ start / หมดอายุ

ใน `gen` เพิ่ม:

```json
"ocLoginUser": "ocpadmin",
"ocLoginPassword": "ocp@dmin!",
"ocLoginServers": {
  "cwdc": "https://api.cwdc.esb-kafka-prod.intra.ais:6443",
  "tls2": "https://api.tls2.esb-kafka-prod.intra.ais:6443"
}
```

- **ocLoginUser** / **ocLoginPassword**: user เดียวใช้ได้ทุก context (cwdc, tls2)
- ถ้า context คนละ user ให้ใช้ **ocLoginCredentials** แทน:
  ```json
  "ocLoginCredentials": {
    "cwdc": { "user": "user1", "password": "pass1" },
    "tls2": { "user": "user2", "password": "pass2" }
  }
  ```

**หมายเหตุ:** ไฟล์ config ที่มี password อย่า commit ขึ้น git (เก็บไว้แค่บนเครื่อง deploy หรือใช้ env แทน ดู §3)

### เก็บแบบเข้ารหัส (Encrypt) — อ่านไฟล์แล้วเห็นไม่ตรงๆ

ใส่ใน config เป็น **ciphertext** (ขึ้นต้น `enc:`) แทน plaintext แล้วตั้ง **OC_CREDENTIALS_KEY** ใน env เป็น key ถอดรหัส (32 bytes = 64 ตัวอักษร hex):

```bash
# สร้าง key ครั้งเดียว (เก็บไว้ในที่ปลอดภัย)
export OC_CREDENTIALS_KEY=$(openssl rand -hex 32)

# แปลง password เป็น ciphertext (รันบนเครื่องที่มี Node)
node webapp/scripts/encrypt-oc-password.js "ocp@dmin!"
# ได้ค่า enc:xxxx — เอาไปใส่ใน gen.ocLoginPassword ใน web.config.json
```

ใน config ใส่ `"ocLoginPassword": "enc:xxxx..."` และตอนรัน container **ต้องส่ง** `-e OC_CREDENTIALS_KEY=$OC_CREDENTIALS_KEY` (ใน podman-run-config.sh มีส่งให้แล้วถ้ามี export ไว้)

---

## 3. ส่ง Token หรือ User/Password ผ่าน env (ทางเลือก)

Token **ไม่ควร** ใส่ใน config ถ้า config ถูก commit หรือแชร์ — ใช้ **ตัวแปร environment** แทน:

### ทางเลือก A: Token เดียวใช้ได้ทุก context (user เดียวกัน)

ตั้ง env ก่อนรัน container:

```bash
export OC_LOGIN_TOKEN="sha256~xxxxxxxx"
podman run -d ... -e OC_LOGIN_TOKEN="$OC_LOGIN_TOKEN" ...
```

หรือใน config (ไม่แนะนำถ้า config ไม่ได้เก็บเป็นความลับ):

```json
"ocLoginToken": "sha256~xxxxxxxx"
```

### ทางเลือก B: Token คนละตัวต่อ context

ตั้ง env ตาม context (ตัวพิมพ์ใหญ่, ขีดแทนด้วย _):

```bash
export OC_LOGIN_TOKEN_CWDC="sha256~..."
export OC_LOGIN_TOKEN_TLS2="sha256~..."
podman run -d ... -e OC_LOGIN_TOKEN_CWDC -e OC_LOGIN_TOKEN_TLS2 ...
```

หรือใน config ต่อ context:

```json
"ocLoginTokens": {
  "cwdc": "sha256~...",
  "tls2": "sha256~..."
}
```

---

## 4. Mount โฟลเดอร์ .kube แบบ **เขียนได้**

Auto login จะ **เขียน** token ลงไฟล์ kubeconfig ดังนั้น volume ที่ mount ต้อง **ไม่ใช่ read-only**:

- เมื่อ .kube อยู่ภายนอก ROOT ใช้ `-v "$KUBE_DIR:$ROOT/.kube-external:z"` แล้วตั้ง kubeconfigPath เป็น `$ROOT/.kube-external/config` (หรือไฟล์ merged ที่คุณใช้จริง; ไม่มี `ro` ถ้าใช้ ocAutoLogin)
- ถ้าใช้ `:ro,z` อยู่ ให้เอา `ro` ออกเป็น `:z` หรือ `:rw,z`

---

## 5. เอา TOKEN มาจากไหน (ถ้าไม่ใช้ user/password) (ทำครั้งเดียวแล้วใช้กับ Auto Login ได้เรื่อยๆ)

มี 2 ทางหลัก — เลือกทางที่ทำได้บนเครื่องคุณ

### วิธี A: จากเครื่องที่รัน oc ได้ (แนะนำ)

บนเครื่องที่ติดตั้ง `oc` และ **login ได้อยู่แล้ว** (หรือ login ครั้งเดียวด้วย user/password):

```bash
# 1) Login ปกติครั้งเดียว (ถ้ายังไม่ได้ login)
oc login --server=https://api.<cluster>.your-domain.com:6443 -u <username>

# 2) ดึง token ออกมา (ใช้กับ Auto Login ได้)
oc whoami -t
```

ข้อความที่ได้จะเป็นแบบ `sha256~xxxxxxxxxxxxxxxx` — **ค่านี้คือ token** เอาไปใส่ใน `OC_LOGIN_TOKEN` หรือ `OC_LOGIN_TOKEN_CWDC` / `OC_LOGIN_TOKEN_TLS2` ได้เลย

- ถ้า user คนเดียวกันใช้ได้ทั้งสอง cluster (cwdc, tls2) ให้ตั้งตัวเดียว:  
  `export OC_LOGIN_TOKEN="$(oc whoami -t)"`
- ถ้า cluster คนละ user / คนละ token ให้ login เข้าแต่ละ cluster แล้วรัน `oc whoami -t` แยกกัน แล้วตั้ง `OC_LOGIN_TOKEN_CWDC` กับ `OC_LOGIN_TOKEN_TLS2` แยกกัน

**หมายเหตุ:** Token จาก `oc whoami -t` มีอายุ (เช่น 24 ชม.) หมดอายุแล้วต้องเอา token ใหม่แล้ว restart container อีกครั้ง หรือใช้วิธี B เพื่อเอา token ใหม่จาก Web Console ได้ตลอด

---

### วิธี B: จาก OpenShift Web Console

1. เปิด **OpenShift Web Console** (URL ของ cluster นั้น)
2. Login ด้วย user ที่มีสิทธิ์
3. คลิก **ชื่อ user มุมขวาบน** → เลือก **"Copy login command"**
4. ไปที่แท็บ **"Display Token"** จะเห็น token แบบ `sha256~...` — กด copy
5. ใช้ค่านี้เป็น `OC_LOGIN_TOKEN` หรือ `OC_LOGIN_TOKEN_CWDC` / `OC_LOGIN_TOKEN_TLS2`

ทำซ้ำกับอีก cluster ถ้าใช้คนละ context (เช่น cwdc กับ tls2 คนละ token)

---

### Server URL (สำหรับ ocLoginServers ใน config)

- จากเครื่องที่ login แล้ว: รัน `oc whoami --show-server`
- หรือจาก Web Console หลัง login: URL ด้านบนจะเป็น API server ของ cluster นั้น (เช่น `https://api.cwdc....:6443`)

---

## 6. การทำงาน (รวม Session ต่อเนื่องไร้รอยต่อ)

- หลัง server ฟังพอร์ตแล้ว จะรัน `oc login --server=... --token=...` ต่อทุก context ที่มีใน **ocLoginServers**
- **หลัง login เสร็จ**: จะเช็ค session ทุก context ทันที (`oc whoami --context=...`) ถ้าเจอหมดอายุหรือไม่ valid จะทำ auto login ใหม่ทันที
- **ก่อนให้ API กับ User**: ก่อนตอบ `/api/users` จะเช็ค session ก่อนทุกครั้ง — ถ้าหมดอายุจะ re-login ก่อนแล้วค่อยดึงข้อมูล เพื่อไม่ให้ User เจอ Web Error จาก credentials หมดอายุ
- **Periodic check**: เมื่อเปิด ocAutoLogin จะมี timer เช็ค session เป็นระยะ (default ทุก 10 นาที) ถ้าเจอหมดอายุจะทำ auto login ใหม่ให้ session ต่อเนื่อง
- ใน log จะเห็น `[oc-auto-login] cwdc OK` / `[oc-auto-login] tls2 OK` ถ้าสำเร็จ และ `[oc-session-check] เปิด periodic check ทุก 10 นาที`
- ถ้า token ผิดหรือ server ไม่ถึง จะเห็น `[oc-auto-login] <context> failed: ...` ใน log

ต้องการเปลี่ยนความถี่ periodic check: ตั้ง `gen.ocSessionCheckIntervalMinutes` ใน config (จำนวนนาที, ค่าต่ำสุด 5)

---

## 7. สรุปขั้นตอนตั้งค่า Auto Login (ครั้งเดียว)

**ทางง่าย (แนะนำ):** ฝัง user/password ใน config

1. **config**: ใน `web.config.json` ใส่ `gen.ocAutoLogin: true`, `gen.ocLoginServers` (URL ของ cwdc, tls2) และ `gen.ocLoginUser` + `gen.ocLoginPassword` ตาม [§2](#2-ฝัง-userpassword-ใน-config-ทำครั้งเดียวแล้ว-auto-เอง)
2. **mount**: โฟลเดอร์ `.kube` ต้อง mount แบบ **เขียนได้** (ใน `podman-run-config.sh` ใช้ `:z` ไม่มี `:ro`)
3. **restart container** — เว็บจะรัน `oc login -u ... -p ...` ให้อัตโนมัติทุก context

**ทางใช้ token:** เอา token ตาม [§5](#5-เอา-token-มาจากไหน-ถ้าไม่ใช้-userpassword) แล้วตั้ง env `OC_LOGIN_TOKEN` หรือแยกต่อ context แล้ว restart container

หลังนี้ไม่ต้องมานั่ง `oc login` ที่ VM ทุกครั้ง

---

## 8. ปิดใช้

ตั้ง `"ocAutoLogin": false` หรือลบ ocAutoLogin / ocLoginServers ออก แล้ว restart container — พฤติกรรมจะกลับเป็นแบบเดิม (ต้องไป oc login ที่ VM เองก่อน)
