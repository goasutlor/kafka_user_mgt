# Export Path และ Podman Parameter (อ้างอิง)

แก้ path ด้านล่างให้ตรงกับเครื่องแล้ว copy ไปใช้ได้เลย

---

## 1. Export Path (ตัวแปรสำหรับ mount)

```bash
# --- แก้ให้ตรงเครื่องคุณ ---
export CONFIG_HOST="${CONFIG_HOST:-/opt/kafka-usermgmt/Docker/web.config.json}"
export BASE_HOST="${BASE_HOST:-/opt/kafka-usermgmt}"
export OC_DIR="${OC_DIR:-/usr/bin}"
export SSL_DIR="${SSL_DIR:-/opt/kafka-usermgmt/Docker/ssl}"
export KUBE_DIR="${KUBE_DIR:-/opt/kafka-usermgmt/.kube}"

# ชื่อ container / image
export CONTAINER_NAME="${CONTAINER_NAME:-kafka-user-web}"
export IMAGE_NAME="${IMAGE_NAME:-confluent-kafka-user-management:latest}"

# พอร์ต host:container (server ใน image ใช้ 3443 → 443:3443)
export PORT_MAP="${PORT_MAP:-443:3443}"

# Optional: Auto OC Login (ถ้าเปิดใน web.config.json)
# export OC_LOGIN_TOKEN="sha256~xxxxxxxx"
# หรือแยก context: export OC_LOGIN_TOKEN_CWDC="..."; export OC_LOGIN_TOKEN_TLS2="..."
```

---

## 2. Podman run (คำสั่งเต็ม)

```bash
podman run -d --name "$CONTAINER_NAME" --userns=keep-id --security-opt label=disable -p "$PORT_MAP" \
  -v "$CONFIG_HOST:/app/config/web.config.json:ro,z" \
  -v "$BASE_HOST:$BASE_HOST:ro,z" \
  -v "$OC_DIR:/host/usr/bin:ro,z" \
  -v "$SSL_DIR/server.key:/app/ssl/server.key:ro,z" \
  -v "$SSL_DIR/server.crt:/app/ssl/server.crt:ro,z" \
  -v "$KUBE_DIR:$BASE_HOST/.kube-external:z" \
  -e CONFIG_PATH=/app/config/web.config.json \
  "$IMAGE_NAME"
```

ถ้าใช้ Auto OC Login ให้เพิ่มก่อน `"$IMAGE_NAME"`:

```bash
  -e OC_LOGIN_TOKEN="$OC_LOGIN_TOKEN" \
  # หรือ -e OC_LOGIN_TOKEN_CWDC="..." -e OC_LOGIN_TOKEN_TLS2="..."
  "$IMAGE_NAME"
```

---

## 3. ใช้จากไฟล์ config (แนะนำ)

```bash
# แก้ path ใน podman-run-config.sh ให้ตรงเครื่อง แล้ว:
source podman-run-config.sh
run_podman_start   # start
run_podman_stop    # stop
```

หรือรัน script โดยตรง (จะ stop เดิมแล้ว start ใหม่):

```bash
./podman-run-config.sh
```

---

## 4. โหลด image จากไฟล์ .tar (หลัง build-export-image.sh)

```bash
podman load -i confluent-kafka-user-management-0.0.0.tar
```

จากนั้นใช้ Export Path + Podman run ด้านบน (หรือ `source podman-run-config.sh` แล้ว `run_podman_start`)

---

## 5. HTTPS แบบ Prod (TLS ที่ Node — ไม่ต้องมี Nginx)

- วาง `server.key` + `server.crt` (เช่น self-signed CN=hostname เหมือนเครื่อง Prod) ใต้ `SSL_DIR` — `podman-run-config.sh` mount ไป `/app/ssl/` อยู่แล้ว
- ถ้ามีไฟล์ทั้งคู่ สคริปต์ส่ง **`USE_HTTPS=1`** ให้อัตโนมัติ
- อยากให้พอร์ต 443 เป็น HTTP ชั่วคราว: **`export USE_HTTPS=0`** ก่อน `run_podman_start`
- หลัง first-time setup เคยรันแบบ HTTP: **restart container** หลังมี config ครบ แล้วค่อยเปิด HTTPS
- **Docker Compose:** ใน `.env` ใส่ `USE_HTTPS=1` และ uncomment volume `./deploy/ssl:/app/ssl:ro` ใน `docker-compose.yml`

### 5.1 ทางเลือก: TLS ที่ reverse proxy เท่านั้น

ถ้าองค์กรบังคับใบที่ LB/Nginx: ให้แอปเป็น HTTP + **`TRUST_PROXY=1`** และ proxy ส่ง **`X-Forwarded-Proto: https`** (ไม่ส่ง `USE_HTTPS` ที่ Node)
