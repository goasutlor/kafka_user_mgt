# Add New User ทำไม่ได้จริง — ไล่จุดอย่างไร

เมื่อกด **Create user + ACL** แล้วไม่สำเร็จ ใช้ลำดับด้านล่างไล่ให้เจอสาเหตุแล้วแก้ให้ตรงจุด

---

## ขั้นที่ 1: ดู error ที่ได้

**จาก Web UI** — ข้อความสีแดงที่โผล่หลังกด Create คืออะไร เช่น  
`spawn bash ENOENT` / `gen.sh not found at ...` / `gen.sh exited 1` / อื่นๆ

**จาก container** — รันแล้วดู log:

```bash
podman logs kafka-user-web
# หรือดูส่วนท้าย
podman logs --tail 100 kafka-user-web
```

จด error หลักไว้ (บรรทัดที่มี Error / ENOENT / not found / exited)

---

## ขั้นที่ 2: แก้ตามอาการที่เห็น

### อาการ: `spawn bash ENOENT`

- **สาเหตุ:** ใน container ไม่มีคำสั่ง `bash` (image เก่าที่ build ก่อนเพิ่ม bash)
- **แก้:** ใช้ image ที่ build จาก Dockerfile ปัจจุบัน (มี `RUN apk add --no-cache bash`)
  - บนเครื่อง build: `docker build -t confluent-kafka-user-management:latest .` แล้ว export .tar ใหม่
  - บน Helper Node: `podman load -i confluent-kafka-user-management.tar` แล้วรัน container ใหม่

### อาการ: ดึง topic หรือ user ไม่ได้ (Load topic list / Load existing users)

- **ดึง topic ไม่ได้:** API เรียก `kafka-topics.sh --list` — ต้อง mount โฟลเดอร์ที่มี **kafkaBin** และ **adminConfig** (path ใน config ต้องเป็น path ที่ container เห็น) และ Kafka bootstrap ต้องเข้าถึงได้; ถ้า bootstrap ไม่ตรง ให้ตั้ง **gen.bootstrapServers** ใน config
- **ดึง user ไม่ได้:** API เรียก `oc get secret` ต่อ **ทุก site** ที่ตั้งใน gen.sites — ต้องมี **oc** ใน PATH (gen.ocPath), **gen.kubeconfigPath** และ **gen.sites** (หรือ legacy: gen.namespace + gen.ocContext) ให้ตรงกับ OCP **ทุก cluster** ที่ใช้ (ต้องเข้าได้ครบทุกที่)
- หน้า Web จะแสดงข้อความ error จาก backend (ดึง topic ไม่ได้: ... / ดึง user ไม่ได้: ...) ใช้ข้อความนั้นไล่แก้

### อาการ: `the server has asked for the client to provide credentials` (ดึง user ไม่ได้ — cwdc/tls2 ขึ้น credentials)

- **สาเหตุ:** Token ใน kubeconfig หมดอายุหรือไม่ถูกต้อง — container ใช้ไฟล์ kubeconfig ที่ mount จาก host แต่ token ข้างในหมดอายุหรือเป็นของ user อื่น
- **เทสบน host ก่อน deploy (ไม่ต้องรัน container):** รันสคริปต์นี้บนเครื่องที่จะ mount .kube (ต้องมี oc + jq) — ถ้า PASS แปลว่า credentials ใช้ได้ พอ deploy/restart แล้ว GET /api/users ควรได้
  ```bash
  ./scripts/check-oc-users-from-config.sh
  # หรือส่ง path config: ./scripts/check-oc-users-from-config.sh /opt/kafka-usermgmt/Docker/web.config.json
  ```
- **แก้ให้ตรงจุด:**
  1. **บน host (user ที่เป็นเจ้าของไฟล์ .kube ที่ mount เข้า container)** รัน `oc login` ใหม่ให้ครบ **ทุก cluster** ที่ใช้ใน gen.sites (cwdc, tls2 ฯลฯ) — ให้ใช้ไฟล์ kubeconfig ชุดเดียวกับที่ชี้ใน gen.kubeconfigPath (เช่น `/opt/kafka-usermgmt/.kube/config-both`)
  2. ตรวจว่า login ผ่าน: รัน `./scripts/check-oc-users-from-config.sh` อีกครั้ง ต้อง PASS อย่างน้อย 1 site
  3. **Restart container** เพื่อให้อ่าน kubeconfig ใหม่: `podman restart kafka-user-web`
- ถ้า login บน host ผ่านแต่ใน container ยัง fail: ตรวจว่า mount ถูกไฟล์จริง (ไม่ใช่โฟลเดอร์เปล่าหรือคนละไฟล์) และ path ใน config ตรงกับ path ใน container
- **ถ้า helper ที่รัน gen.sh บน host เข้าได้ทั้ง cwdc/tls2 ปกติ แต่ Web (ใน container) ขึ้น credentials:** container ใช้ไฟล์ kubeconfig ชุดเดียวกับที่ mount จาก host — แปลว่า (1) path ใน **gen.kubeconfigPath** ต้องชี้ไปที่ไฟล์นั้นจริงใน container (เช่น `$ROOT/.kube/config-both` ถ้า mount เป็น `-v "$ROOT:$ROOT:z"`) และ (2) token ในไฟล์อาจหมดอายุระหว่างที่ helper รันกับที่ container อ่าน → บน host รัน `oc login` ใหม่ให้ครบทุก context ที่ใช้ (cwdc, tls2) แล้ว **restart container** หรือเปิดใช้ **ocAutoLogin** (ดู `OC-AUTO-LOGIN.md`) ให้แอปรัน oc login เองเมื่อ token หมดอายุ

### อาการ: `error: context "..." does not exist` (ดึง user ไม่ได้ไม่หาย)

- **สาเหตุ:** ใน container ไฟล์ kubeconfig ที่ใช้ (gen.kubeconfigPath) ไม่มีอยู่หรือไม่มี context ครบทุกตัวที่ระบุใน gen.sites (แต่ละ site = 1 cluster OCP ต้องเข้าได้ทั้งคู่)
- **แก้ให้ตรงจุด:**
  1. **web.config.json** ใช้ **gen.sites** กำหนดทุก cluster (ชื่อ site, namespace, ocContext ตามจริง) และ **kubeconfigPath** ชี้ไปที่ไฟล์ kubeconfig ที่มี context **ครบทุกตัว** ใน gen.sites
  2. **รัน container** ต้องมี path ที่ gen.kubeconfigPath ชี้ไป — เมื่อทุกอย่างอยู่ใต้ ROOT (เช่น `/opt/kafka-usermgmt`) แล้ว .kube อยู่ที่ `ROOT/.kube` ไม่ต้อง mount แยก; ถ้า .kube อยู่ภายนอก ROOT ให้ mount เป็น `-v "$KUBE_DIR:$ROOT/.kube-external:z"` (ดู podman-run-config.sh)
  3. **บน host** ตรวจว่าไฟล์มี context ครบทุกตัวที่ใช้: `KUBECONFIG=<path> oc config get-contexts` ต้องเห็นครบทุก context ที่ระบุใน gen.sites
  4. **หลังแก้ config หรือ mount** ต้อง **restart container** (`podman restart kafka-user-web`) เพราะแอปโหลด config ตอนเริ่มต้น
- หลังอัปเดต backend ล่าสุด หน้า Web จะแสดงข้อความละเอียดขึ้น (เช่น ไฟล์ไม่พบที่ path ไหน, context ที่เห็นใน container มีอะไรบ้าง) ใช้ช่วยไล่ต่อได้

### อาการ: `gen.sh not found at /path/to/script`

- **สาเหตุ:** path ใน config ไม่ตรงกับที่ container เห็น (ไฟล์ไม่มีหรืออยู่คนละ path)
- **เช็คบน Helper Node:**
  ```bash
  # path ต้องตรงกับที่เขียนใน web.config.json (scriptPath)
  ls -la /opt/kafka-usermgmt/gen.sh
  ```
- **แก้:** ใน `web.config.json` ตั้ง `scriptPath` ให้ชี้ไปที่ path จริงที่ **container เห็น** (เช่น `/opt/kafka-usermgmt/gen.sh` เมื่อ mount เป็น -v ROOT:ROOT) และให้แน่ใจว่า ROOT ถูก mount ตอนรัน container

### อาการ: `gen.sh exited 1` (หรือ exit code อื่นที่ไม่ใช่ 0)

- **สาเหตุ:** สคริปต์รันได้ แต่ล้ม inside (topic ไม่มี, oc ไม่เชื่อม, user ซ้ำ ฯลฯ)
- **ดูรายละเอียด:** ใน API response หรือใน log มักมี `stderr` / `stdout` จาก gen.sh อยู่ — ดูว่าบรรทัดไหนบอก error
- **เช็คด้วยการรัน script ด้วยมือ** บน Helper Node (ในโฟลเดอร์ที่มี script):

  ```bash
  cd /opt/kafka-usermgmt

  export GEN_NONINTERACTIVE=1
  export GEN_MODE=1
  export GEN_SYSTEM_NAME=TestSystem
  export GEN_TOPIC_NAME=your_topic_ที่มีจริง
  export GEN_KAFKA_USER=testuser999
  export GEN_ACL=2
  export GEN_PASSPHRASE=testpass123

  bash confluent-usermanagement.sh
  ```

  ดู output ว่า error อะไร (topic not found / oc not found / user already exists / secret ไม่ได้ ฯลฯ) แล้วแก้ที่ environment หรือที่ OCP/Kafka ตามนั้น

---

## ขั้นที่ 3: เช็คว่า script กับ config ตรงกัน

- **ชื่อไฟล์:** ใน config คุณใช้ `confluent-usermanagement.sh` — บนเครื่องต้องมีไฟล์นี้จริง (หรือ symlink/copy จาก `gen.sh`)
- **สิทธิ์:** script ต้องรันได้  
  `chmod +x /app/user2/kotestkafka/confluent-usermanagement.sh`
- **PATH ใน container:** ตอนรัน container ต้อง mount โฟลเดอร์ที่มี `oc` (เช่น `-v /usr/bin:/usr/bin:ro`). Image ที่ build จาก Dockerfile ปัจจุบันมี `bash` และ `jq` อยู่แล้ว (gen.sh ใช้ทั้งคู่)

---

## สรุปสั้นๆ

| Error ที่เห็น | ทำอะไร |
|---------------|--------|
| `spawn bash ENOENT` | ใช้ image ใหม่ที่ build จาก Dockerfile ที่มี `apk add bash` แล้ว load/run ใหม่ |
| `gen.sh not found at ...` | แก้ `scriptPath` ใน config ให้ตรงกับ path จริงใน container + เช็ค mount |
| `gen.sh exited 1` (หรือไม่ใช่ 0) | ดู stderr/stdout ใน log/response แล้วรัน script ด้วยมือ (คำสั่งด้านบน) เพื่อดู error จริง แล้วแก้ที่ topic/oc/user/secret ฯลฯ |
| **ดาวน์โหลด .enc ไม่ได้ (404 File not found)** | ดูด้านล่าง § Download .enc ไม่ได้ |

### อาการ: ดาวน์โหลด .enc ไม่ได้ (404 File not found)

- **สาเหตุ:** Server หาไฟล์ .enc ไม่เจอ — ไฟล์ถูกสร้างโดย gen.sh ในโฟลเดอร์ที่ script รัน (cwd = โฟลเดอร์ของ scriptPath) แต่ server อาจมองคนละ path, mount ไม่ตรง หรือรันหลาย instance (add-user รันที่ pod A แต่ download ไปที่ pod B)
- **เช็ค log:** รัน `podman logs kafka-user-web` แล้วดูบรรทัด `[download] <filename> not found. Tried: <path1>, <path2>, ...` — จะเห็นว่า server ไปหาไฟล์ที่ path ไหนบ้าง
- **แก้:**  
  (1) ให้แน่ใจว่า container mount โฟลเดอร์เดียวกับที่ gen.sh เขียนไฟล์ (เช่น `-v "$BASE_HOST:$BASE_HOST:ro,z"` และ scriptPath/baseDir ชี้ไปที่ path นั้น)  
  (2) ตั้ง **gen.downloadDir** ใน web.config.json ให้ชี้ไปที่โฟลเดอร์ที่ gen.sh สร้างไฟล์ .enc (เช่น `/opt/kafka-usermgmt/user_output` หรือ baseDir/user_output) — config ตัวอย่างมี downloadDir อยู่แล้ว  
  (3) ถ้ารันหลาย pod/instance ต้องให้ request add-user กับ download ไปที่ instance เดียวกัน (sticky session) หรือให้โฟลเดอร์ .enc เป็น shared volume ที่ทุก pod เห็น  
  (4) **lastPackDir เป็น (none):** แปลว่าสคริปต์บน server ยังไม่ส่ง GEN_PACK_DIR — ต้องอัปเดต **gen.sh** (หรือไฟล์ที่ config ชี้ เช่น confluent-usermanagement.sh) ให้มีบรรทัด `echo "GEN_PACK_DIR=$(pwd)"` ก่อนบรรทัด `echo "GEN_PACK_FILE=..."` แล้ว restart server. หลังอัปเดต add-user จะส่ง path จริงที่สร้างไฟล์มา server จะใช้ path นั้นหาไฟล์โหลด  
  (5) Restart container หลังแก้ config

ถ้าทำครบแล้ว Add New User ยังทำไม่ได้จริง ให้จด **ข้อความ error เต็ม** จาก UI และจาก `podman logs kafka-user-web` (โดยเฉพาะส่วนที่เกี่ยวกับ add-user) ไว้ แล้วใช้เอกสารนี้ไล่ต่อหรือส่งต่อให้คนดูแลระบบช่วยดูได้ครับ
