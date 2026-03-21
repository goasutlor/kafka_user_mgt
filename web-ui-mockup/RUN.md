# รัน Web UI บน Helper Node (Docker / Podman)

## บน Helper Node ต้องติดตั้งอะไรบ้าง

| สิ่งที่ต้องมี | หมายเหตุ |
|---------------|----------|
| **Docker** หรือ **Podman** | อย่างใดอย่างหนึ่งพอ (ไม่ต้องติดตั้งทั้งคู่) |
| (มีอยู่แล้ว) | เครื่องที่รัน `gen.sh` อยู่แล้วมี `oc`, Kafka client, `jq` — ไม่ต้องติดตั้งเพิ่มสำหรับแค่ UI ตัวนี้ |

สำหรับ **แค่แสดง UI ตัวอย่าง (static)** ไม่ต้องติดตั้งอะไรเพิ่มนอกจาก Docker หรือ Podman  
ถ้าอนาคตมี **backend** ที่ไปรัน `oc` / Kafka เองใน container ค่อย mount path ของ Kafka + kubeconfig (ดูด้านล่าง)

---

## รันแบบ container เดียว (Docker หรือ Podman)

### 1. Build image

จากโฟลเดอร์ที่อยู่ระดับเดียวกับ `web-ui-mockup` (เช่น `gen-kafka-user`):

```bash
cd /path/to/gen-kafka-user
docker build -t kafka-provisioning-ui:latest ./web-ui-mockup
```

หรือใช้ Podman:

```bash
podman build -t kafka-provisioning-ui:latest ./web-ui-mockup
```

### 2. Run

**Docker:**

```bash
docker run -d --name kafka-ui -p 8080:80 kafka-provisioning-ui:latest
```

**Podman:**

```bash
podman run -d --name kafka-ui -p 8080:80 kafka-provisioning-ui:latest
```

จากนั้นเปิดเบราว์เซอร์ที่ `http://<helper-node-ip>:8080`

### 3. Stop / ลบ container

```bash
# Docker
docker stop kafka-ui && docker rm kafka-ui

# Podman
podman stop kafka-ui && podman rm kafka-ui
```

---

## ตัวอย่างรันแบบมี volume (ถ้าอนาคตมี backend ที่ใช้ไฟล์จาก host)

ถ้า backend ต้องใช้ `gen.sh`, `oc`, Kafka bin จาก Helper Node ให้ mount เข้าไป:

```bash
# ตัวอย่าง (ปรับ path ตามเครื่องจริง)
export BASE_DIR=/opt/kafka-usermgmt
export KAFKA_BIN=$BASE_DIR/kafka_2.13-3.6.1/bin

podman run -d --name kafka-ui -p 8080:80 \
  -v "$BASE_DIR:$BASE_DIR:ro" \
  -v "$HOME/.kube:$HOME/.kube:ro" \
  kafka-provisioning-ui:latest
```

ตอนนี้ image นี้เป็นแค่ nginx เสิร์ฟ static ไม่ได้รัน backend แบบนี้ — ใช้เมื่อมี backend ที่อ่าน path เหล่านี้แล้วค่อยใช้คำสั่งนี้

---

## สรุป

- **ติดตั้ง:** เฉพาะ Docker หรือ Podman บน Helper Node (และของเดิมที่ใช้กับ gen.sh อยู่แล้ว)
- **รัน:** Build หนึ่ง image แล้ว `docker run` หรือ `podman run` ตัวเดียว พอร์ต 8080 → เปิดเบราว์เซอร์ที่ `http://<helper-node>:8080`
