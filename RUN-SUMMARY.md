# สรุปวิธี Run — Confluent Kafka User Management

มี **2 ทาง** เลือกอย่างใดอย่างหนึ่ง

---

## ทางที่ 1: รันด้วย Docker / Podman (ไม่ต้องติด Node)

**ใช้เมื่อ:** มีไฟล์ **confluent-kafka-user-management.tar** และรันบนเครื่องที่มี gen.sh, oc, Kafka อยู่แล้ว (เช่น Helper Node)

### ขั้นตอนสั้นๆ

**1) โหลด image**
```bash
podman load -i confluent-kafka-user-management.tar
```

**2) เตรียม config + cert (ถ้าใช้ HTTPS 443)**

- ไฟล์ **web.config.json** ตั้ง `server.port: 443` และ `server.https` (keyPath, certPath)
- มีโฟลเดอร์ ssl มีไฟล์ server.key, server.crt

**3) รัน container**
```bash
export CONFIG_HOST=/app/user2/kotestkafka/Docker/web.config.json
export BASE_HOST=/app/user2/kotestkafka
export OC_DIR=/usr/bin
export SSL_DIR=/app/user2/kotestkafka/Docker/ssl

podman run -d --name kafka-user-web --userns=keep-id --security-opt label=disable -p 443:443 \
  -v "$CONFIG_HOST:/app/config/web.config.json:ro" \
  -v "$BASE_HOST:$BASE_HOST:ro" \
  -v "$OC_DIR:$OC_DIR:ro" \
  -v "$SSL_DIR/server.key:/app/ssl/server.key:ro" \
  -v "$SSL_DIR/server.crt:/app/ssl/server.crt:ro" \
  -e CONFIG_PATH=/app/config/web.config.json \
  docker.io/library/confluent-kafka-user-management:latest
```

**4) เปิดใช้**

เปิดเบราว์เซอร์: **https://\<IP-เครื่อง>** (เช่น https://<portal-host>)

**5) หยุด / ดู log**
```bash
podman logs -f kafka-user-web
podman stop kafka-user-web
podman rm kafka-user-web
```

---

## ทางที่ 2: รัน Node ตรงๆ (มีแค่ Node 18+)

**ใช้เมื่อ:** ไม่อยากใช้ Docker อยากรันด้วย Node ตรงๆ

### ขั้นตอนสั้นๆ

**1) โฟลเดอร์ที่รันต้องมี**
- gen.sh (หรือ confluent-usermanagement.sh)
- run-node.sh
- webapp/
- web-ui-mockup/
- configs/ และ web.config.json (แก้ path ตรงกับเครื่อง)

**2) รัน**
```bash
cd /app/user2/kotestkafka   # โฟลเดอร์ที่มี gen.sh
./run-node.sh
```

**3) เปิดใช้**

เปิดเบราว์เซอร์ที่ **http://\<IP>:3000** (หรือ port ใน config; ถ้าใช้ HTTPS 443 แก้ config แล้วรันด้วย root หรือ setcap)

---

## เทสก่อน Deploy จริง

รันสคริปต์เช็คให้ครบ **11/11** ก่อน:

```bash
./scripts/check-deployment.sh https://<portal-host>
```

ครบแล้วค่อย deploy จริง

---

## อ้างอิง

- รัน Docker แบบละเอียด (Windows, Linux, HTTPS, 443): [RUN-AFTER-LOAD.md](RUN-AFTER-LOAD.md)
- ติดตั้ง + config: [INSTALL.md](INSTALL.md)
- เทสใน Lab + E2E: [TEST-BEFORE-DEPLOY.md](TEST-BEFORE-DEPLOY.md)
- แก้ปัญหา Add user / ดึง topic-user ไม่ได้: [ADD-USER-TROUBLESHOOT.md](ADD-USER-TROUBLESHOOT.md)
