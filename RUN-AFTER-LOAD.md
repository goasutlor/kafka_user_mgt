# หลัง docker load แล้ว — รัน Web

ใช้เมื่อโหลด image แล้ว (`docker load -i confluent-kafka-user-management.tar`) และต้องการรัน container

**ถ้าไม่อยากใช้ Docker:** รัน Node ตรงๆ ได้ — จากโฟลเดอร์โปรเจกต์รัน `./run-node.sh` (Linux/Mac) หรือ `.\run-node.ps1` (Windows). ติดแค่ Node 18+ กับ dependency เดียว (express). ดู [INSTALL.md](INSTALL.md) วิธีที่ 1

---

## บน Windows (PowerShell)

**1) เตรียม config**

ให้มีไฟล์ **web.config.json** ที่ path ใน config ชี้ไปที่โฟลเดอร์ที่มี `gen.sh` และ configs ของ Kafka  
(ถ้ารันบน Windows เพื่อดู UI อย่างเดียว อาจใช้ `webapp\config\web.config.json` ได้ แต่ Add user จะ error จนกว่าจะไปรันบนเครื่องที่มี gen.sh จริง เช่น Linux)

**2) รัน container**

ใช้ mount เป็น `/workspace` ใน container และใช้ **forward slash** ใน path (`D:/...`) เพื่อไม่ให้ `D:` ไปชนกับตัวแบ่ง `:` ของ Docker:

```powershell
# ใช้ forward slash ใน path (สำคัญบน Windows)
docker run -d --name kafka-user-web -p 3000:3000 `
  -v "D:/Project1/gen-kafka-user:/workspace:ro" `
  -v "D:/Project1/gen-kafka-user/webapp/config/web.config.windows-docker.json:/app/config/web.config.json:ro" `
  -e CONFIG_PATH=/app/config/web.config.json `
  confluent-kafka-user-management:latest
```

ถ้าโปรเจกต์อยู่คนละ drive/path แก้ `D:/Project1/gen-kafka-user` ให้ตรงกับโฟลเดอร์คุณ (ใช้ `/` ไม่ใช้ `\`)

ถ้า **gen.sh อยู่บน Linux (Helper Node)** — ควรไปรันคำสั่ง `docker run` บน Linux แทน (ดูส่วน Linux ด้านล่าง) เพราะ Web ต้องเรียก gen.sh, oc และ Kafka bin

**3) เปิดใช้**

เปิดเบราว์เซอร์: **http://localhost:3000**

**4) หยุด / ลบ container**

```powershell
docker stop kafka-user-web
docker rm kafka-user-web
```

---

## บน Linux (เครื่องที่มี gen.sh, oc, Kafka)

**1) เตรียมโฟลเดอร์**

ให้มีโฟลเดอร์ (เช่น `/app/user2/kotestkafka`) ที่มี:
- `gen.sh`
- `configs/kafka-client.properties`, `configs/kafka-client-master.properties`
- โฟลเดอร์ Kafka bin
- ไฟล์ **web.config.json** (แก้ `scriptPath`, `baseDir`, `kafkaBin` ให้ตรงกับ path นี้)

**2) รัน container**

```bash
export CONFIG_HOST=/app/user2/kotestkafka/web.config.json
export BASE_HOST=/app/user2/kotestkafka
export OC_DIR=/usr/bin

docker run -d --name kafka-user-web -p 3000:3000 \
  -v "$CONFIG_HOST:/app/config/web.config.json:ro" \
  -v "$BASE_HOST:$BASE_HOST:ro" \
  -v "$OC_DIR:$OC_DIR:ro" \
  -e CONFIG_PATH=/app/config/web.config.json \
  confluent-kafka-user-management:latest
```

**3) เปิดใช้**

เปิดเบราว์เซอร์: **http://\<IP-เครื่อง>:3000**

**4) ดู log / หยุด / เช็คเวอร์ชัน**

```bash
docker logs -f kafka-user-web
docker stop kafka-user-web
docker rm kafka-user-web
```

ดูว่าเป็น image ใหม่หรือเก่า: ใน log จะมี `version 1.0.0` (หรือเลขที่ build ใส่ไว้) หรือเปิด **https://\<IP>/api/version** / ดูที่ sidebar หน้า Web จะแสดง "· v1.0.0"

---

## ถ้าเปิด Firewall แค่พอร์ต 443

ถ้าเครือข่ายเปิด **พอร์ต 443 เท่านั้น** ให้รัน Web บน **port 443 + HTTPS** ดังนี้:

- **Config:** ตั้ง `server.port` เป็น **443** และเปิด `server.https` (keyPath, certPath) — ดูตัวอย่างด้านล่างในหัวข้อ "รันแบบ HTTPS"
- **Container:** map พอร์ต **443:443** (เช่น `-p 443:443`) และรันด้วยสิทธิ์ที่ bind พอร์ต 443 ได้ (บน Linux ปกติต้อง root หรือตั้ง `net.ipv4.ip_unprivileged_port_start=443` แล้วรันแบบ rootless)
- **รัน Node ตรงๆ:** ตั้ง `"port": 443` ใน config และเปิด HTTPS — รันด้วย **root** หรือใช้ `setcap` ให้ process bind พอร์ต 443 ได้

จากนั้นเปิด **https://\<IP-เครื่อง>** (ไม่ต้องใส่ :443 เพราะเป็น default ของ HTTPS)

---

## รันแบบ HTTPS (Podman/Docker)

ถ้าต้องการให้เปิดผ่าน **https://** ทำ 3 อย่าง: เตรียม certificate, แก้ config, รัน container โดย mount cert และ map port (ใช้ **443** ถ้า firewall เปิดแค่ 443)

### 1) เตรียมไฟล์ certificate บนเครื่อง

**ถ้ามี cert อยู่แล้ว** — ใช้ path ไปที่ไฟล์ `.key` และ `.crt` (หรือ `.pem`)

**ถ้ายังไม่มี (สร้าง self-signed สำหรับใช้ในเครือข่ายภายใน):**

```bash
mkdir -p /app/user2/Docker/ssl
cd /app/user2/Docker/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout server.key -out server.crt \
  -subj "/CN=PKAFKAW401G"
```

จะได้ `server.key` และ `server.crt` ในโฟลเดอร์นี้

### 2) แก้ web.config.json

ใน `server` ให้ตั้ง port เป็น **443** (ถ้า firewall เปิดแค่ 443) และเพิ่ม `https` (path ด้านล่างเป็น **path ใน container** — จะ mount ไฟล์จาก host เข้าไปที่ `/app/ssl/`):

```json
"server": {
  "port": 443,
  "https": {
    "enabled": true,
    "keyPath": "/app/ssl/server.key",
    "certPath": "/app/ssl/server.crt"
  }
}
```

ถ้า firewall เปิดพอร์ตอื่นได้ (เช่น 3443) ใช้ `"port": 3443` แล้ว map `-p 3443:3443` ก็ได้

### 3) รัน container (mount cert + map port 443)

สมมติ cert อยู่ที่ `/app/user2/kotestkafka/Docker/ssl/` (โฟลเดอร์ Docker อยู่ใต้ kotestkafka):

**Export Path (แก้ path ให้ตรงเครื่อง):**
```bash
export CONFIG_HOST=/app/user2/kotestkafka/Docker/web.config.json
export BASE_HOST=/app/user2/kotestkafka
export OC_DIR=/usr/bin
export SSL_DIR=/app/user2/kotestkafka/Docker/ssl
export KUBE_DIR=/app/user2/.kube
```

**Podman Option (ถ้า server ใช้พอร์ต 3443 ใน config ใช้ `-p 443:3443`; ใช้ oc จาก host ที่ /host/usr/bin + kubeconfig):**
```bash
podman run -d --name kafka-user-web --userns=keep-id --security-opt label=disable -p 443:3443 \
  -v "$CONFIG_HOST:/app/config/web.config.json:ro,z" \
  -v "$BASE_HOST:$BASE_HOST:ro,z" \
  -v "$OC_DIR:/host/usr/bin:ro,z" \
  -v "$SSL_DIR/server.key:/app/ssl/server.key:ro,z" \
  -v "$SSL_DIR/server.crt:/app/ssl/server.crt:ro,z" \
  -v "$KUBE_DIR:/app/user2/.kube:ro,z" \
  -e CONFIG_PATH=/app/config/web.config.json \
  confluent-kafka-user-management:latest
```
ถ้าใน config ตั้ง `"port": 443` ให้ใช้ `-p 443:443` แทน `-p 443:3443`

**หมายเหตุ (rootless Podman):** ถ้า bind พอร์ต 443 ไม่ได้ (EACCES) ให้รันด้วย **root** หรือตั้ง `sysctl net.ipv4.ip_unprivileged_port_start=443` แล้วรันใหม่  
ถ้าเจอ `EACCES` ตอนอ่าน config ให้ใส่ `--userns=keep-id` และ `--security-opt label=disable`

จากนั้นเปิด **https://\<IP-เครื่อง>** (พอร์ต 443 เป็น default ของ HTTPS ไม่ต้องใส่ :443) (ถ้าใช้ self-signed เบราว์เซอร์จะเตือน — กดดำเนินการต่อได้ในเครือข่ายภายใน)

---

### 4) ให้ user2 รัน container บนพอร์ต 443 (แนะนำถ้า root เห็น context ไม่ตรงกับ user2)

เมื่อ **root** รัน `oc config get-contexts` กับ kubeconfig ของ user2 บางระบบจะ merge กับ `/root/.kube/config` ทำให้ไม่เห็น context ที่ตั้งใน gen.sites. ทางเลือก: **ให้ user2 รัน container เอง** แล้วใช้พอร์ต 443 ได้โดยตั้ง sysctl ครั้งเดียว

**ขั้นตอน:**

1. **ให้ user ธรรมดา bind พอร์ต 443 ได้ (รันด้วย root ครั้งเดียว):**
   ```bash
   sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443
   ```
   ให้คงค่าตอน reboot:
   ```bash
   echo 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee /etc/sysctl.d/99-unprivileged-443.conf
   sudo sysctl -p /etc/sysctl.d/99-unprivileged-443.conf
   ```

2. **หยุด container เดิม (ถ้ารันด้วย root อยู่):**
   ```bash
   sudo podman stop kafka-user-web
   sudo podman rm kafka-user-web
   ```

3. **ล็อกอินเป็น user2** แล้วรัน container (ไม่ใช้ sudo) — ต้อง mount kubeconfig ของ user2 เพื่อให้ oc ใน container อ่าน context **ทุกตัว** ที่ระบุใน gen.sites (ต้องเข้าได้ทุก cluster OCP)

   **Export Path (แก้ path ให้ตรงเครื่อง):**
   ```bash
   export CONFIG_HOST=/app/user2/kotestkafka/Docker/web.config.json
   export BASE_HOST=/app/user2/kotestkafka
   export OC_DIR=/usr/bin
   export SSL_DIR=/app/user2/kotestkafka/Docker/ssl
   export KUBE_DIR=/app/user2/.kube
   ```
   ถ้า server ใช้พอร์ต 3443 ใน config ให้ map `-p 443:3443`; ถ้าใช้ 443 ให้ map `-p 443:443`

   **Podman Option (แก้ไข — mount .kube ที่ /app/user2/.kube เพื่อให้ kubeconfigPath ใช้ได้):**
   ```bash
   podman run -d --name kafka-user-web --userns=keep-id --security-opt label=disable -p 443:3443 \
     -v "$CONFIG_HOST:/app/config/web.config.json:ro,z" \
     -v "$BASE_HOST:$BASE_HOST:ro,z" \
     -v "$OC_DIR:/host/usr/bin:ro,z" \
     -v "$SSL_DIR/server.key:/app/ssl/server.key:ro,z" \
     -v "$SSL_DIR/server.crt:/app/ssl/server.crt:ro,z" \
     -v "$KUBE_DIR:/app/user2/.kube:ro,z" \
     -e CONFIG_PATH=/app/config/web.config.json \
     confluent-kafka-user-management:latest
   ```
   - Mount `/app/user2/.kube` ให้ path ใน container = path บน host เพื่อให้ kubeconfigPath ใน config ชี้ไปที่ไฟล์ที่มี **context ครบทุก site** ที่ระบุใน gen.sites
   - ถ้าใน config ตั้ง `"port": 443` ให้เปลี่ยนเป็น `-p 443:443`

4. **web.config.json** ต้องมี **kubeconfigPath** ชี้ไปที่ไฟล์ kubeconfig ที่มี context **ครบทุก cluster** ตาม gen.sites และ **gen.sites** กำหนด namespace + ocContext ต่อ site (หรือ legacy: gen.namespace + gen.ocContext แค่ site เดียว) — และ **ocPath** = `"/host/usr/bin"` (เมื่อ mount แบบด้านบน — ให้ oc มาจาก host ส่วน grep/dirname ใช้ของ container หลีก error libpcre.so.1)

5. **เช็คก่อน deploy:** รันสคริปต์ตรวจด้วย **user2** จะได้ context ตรงกับใน container:
   ```bash
   ./scripts/check-oc-users.sh /app/user2/.kube/config
   ./scripts/check-deployment.sh https://10.235.160.31
   ```

---

## สรุป

| ขั้น | ทำอะไร |
|------|--------|
| 1 | เตรียม **web.config.json** และโฟลเดอร์ที่มี gen.sh + configs (path ใน config ต้องตรงกับที่ mount) |
| 2 | รัน **docker run** ตามด้านบน (แก้ path ให้ตรงเครื่อง) |
| 3 | เปิด **http://localhost:3000** (หรือ http://\<IP>:3000) |

ถ้า Add user แล้ว error แบบ "gen.sh not found" แปลว่า path ใน web.config ไม่ตรงกับ path ที่ mount หรือยังไม่มี gen.sh ในโฟลเดอร์นั้น — ดู [INSTALL.md](INSTALL.md) ส่วน "แก้ปัญหาเบื้องต้น"

**ถ้าเห็น `spawn bash ENOENT` บน Web:** ใช้ image เก่าที่ไม่มี bash — ต้อง **build image ใหม่** จาก Dockerfile ปัจจุบัน (ที่มี `apk add bash jq`) แล้ว export .tar ใหม่, load และ run container ใหม่ ดู [ADD-USER-TROUBLESHOOT.md](ADD-USER-TROUBLESHOOT.md) รายละเอียด

**ถ้าเห็น `grep: error while loading shared libraries: libpcre.so.1`:** เกิดจาก mount host `/usr/bin` ทับ `/usr/bin` ของ container ทำให้ grep ของ host (ที่ต้องการ libpcre) ถูกเรียกแต่ image ไม่มี libpcre — **แก้:** mount เป็น `/host/usr/bin` แทน และใน web.config.json ตั้ง `ocPath` = `"/host/usr/bin"` (ดูขั้นที่ 3 ด้านบน)
