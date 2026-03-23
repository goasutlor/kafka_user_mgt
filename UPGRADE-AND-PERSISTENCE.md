# อัปเกรด image / engine กับความคงอยู่ของ Configuration

เอกสารนี้อธิบายว่าเมื่อ **อัปเกรด Docker / Podman image** (เช่น `podman pull` + รัน container ใหม่) สิ่งใดเปลี่ยน และสิ่งใด **ไม่ถูกแตะ** โดยออกแบบมาตรฐานของโปรเจกต์นี้ (แยก **image** กับ **ข้อมูลบน host ที่ mount เข้าไป**)

**หลักการสำคัญ:** การอัปเกรดแค่ **engine / image** ไม่จำเป็นต้องทำ Setup ใหม่ — พารามิเตอร์, credentials, bootstrap, API URL ที่บันทึกไว้ใน volume (`deploy/config`, `runtime` ฯลฯ) **ยังใช้ต่อได้** จนกว่าคุณจะลบเองหรือใช้ **Reset config** (`/reset-config.html`) ซึ่งจะล้างเฉพาะเมื่อยืนยันด้วย user/password ของ Portal

---

## สรุปสั้น

| ส่วนที่เปลี่ยนเมื่ออัปเกรด image | ส่วนที่ถือว่า “Keep config” บน host — ไม่ถูก image ใหม่ทับ |
|----------------------------------|-----------------------------------------------------------|
| โค้ดแอปใน image (Node, `webapp/`, static UI) | ไฟล์ใต้ **`deploy/config`** ที่ mount → `/app/config` |
| `gen.sh` / สคริปต์ที่ copy เข้า image | โฟลเดอร์ **`runtime`** ที่ mount → `/opt/kafka-usermgmt` (properties, `user_output`, `.kube` ฯลฯ) |
| Kafka CLI ที่ดาวน์โหลดตอน build image | **kubeconfig** ที่อยู่บน host แล้ว bind เข้า `.kube` (ตาม `container-run-config.sh` / compose) |
| เวอร์ชันแพ็กเกจใน image | **TLS** ที่ mount เป็น `server.key` / `server.crt` (ถ้าใช้) |
| — | ค่า **environment** ที่คุณตั้งใน `.env` / สคริปต์รัน container (ไม่ได้อยู่ใน image) |

**หลักการ:** Image ใหม่แทนที่แค่ **filesystem ภายใน container** ที่ไม่ได้มาจาก volume — ทุกอย่างที่คุณเก็บบน **host แล้ว mount เข้าไป** ยังอยู่บน disk เดิมของ host **ไม่หายเพราะเปลี่ยน image** เท่านั้น

---

## ทำไม Configuration จึง “ไม่กระทบ” ตามปกติเมื่ออัปเกรด

- **Engine / image** = layer ใหม่ของ container (แอปเวอร์ชันใหม่, security patch, dependency)
- **Configuration ของคุณ** = ไฟล์จริงที่อยู่บนเครื่อง host ภายใต้ path ที่คุณ mount (เช่น `/app/user2/kafka-usermgmt-config`, `/app/user2/kafka-usermgmt-runtime`)

การ `podman rm` แล้ว `podman run` ใหม่ด้วย **volume เดิม** จะยังอ่าน **ไฟล์ชุดเดิมบน host** — image ใหม่ไม่ได้ format disk ของคุณและไม่ได้ลบโฟลเดอร์ mount

ดังนั้นในทางปฏิบัติ:

- **`master.config.json` / `credentials.json` / audit** ที่อยู่ใต้ config mount → **คงอยู่**
- **`kafka-client.properties`**, truststore, **`user_output`**, **`.kube/config`** ใต้ runtime mount → **คงอยู่**
- รายการ user ใน OCP secret → **ไม่เกี่ยวกับการอัปเกรด image** (อยู่ที่ cluster)

---

## สิ่งที่ถือว่า “Keep แล้วไม่กระทบจากการเปลี่ยน image” (ตามแบบ deploy มาตรฐาน)

เมื่อคุณ **ไม่ลบโฟลเดอร์บน host** และ **mount path เดิม** ทุกครั้งที่รัน container ใหม่:

1. **`deploy/config` → `/app/config`**  
   - master config, credentials, audit, download history ที่แอปเขียนลง volume  
   - **ไม่อยู่ใน image** → อัปเกรด image **ไม่ทับ**

2. **`runtime` → `/opt/kafka-usermgmt`**  
   - `configs/*.properties`, `user_output/`, แพ็ก `.enc`, และถ้าเก็บ `.kube` ไว้ใต้ runtime แทนการ bind แยก  
   - **ไม่อยู่ใน image** → อัปเกรด image **ไม่ทับ**

3. **Bind `~/.kube` หรือ path เดิม → `/opt/kafka-usermgmt/.kube`**  
   - ไฟล์ kubeconfig อยู่บน host  
   - **ไม่อยู่ใน image** → token/context ยังเป็นของ host (แต่ token หมดอายุเป็นเรื่อง OCP ไม่ใช่เรื่อง image)

4. **`/usr/bin` → `/host/usr/bin` (read-only)**  
   - binary `oc` จาก host  
   - อัปเกรด image **ไม่เปลี่ยน** ไฟล์บน host

5. **SSL mount (ถ้ามี)**  
   - key/cert บน host → **ไม่ถูก image แตะ**

สรุปภาษาชาวบ้าน: **สิ่งที่คุณ “keep” ไว้บน host ตามตาราง mount ด้านบน จะไม่หายเพราะแค่ลาก image ใหม่มาใส่** — เพราะมันไม่ได้อยู่ใน layer ของ image นั้น

---

## ข้อยกเว้น / สิ่งที่ไม่ใช่ “100% อัตโนมัติ”

เพื่อความซื่อสัตย์ทางเทคนิค ไม่มีระบบใดรับประกัน 100% โดยไม่มีเงื่อนไข แต่กรณีต่อไปนี้คือสิ่งที่ **อาจ** กระทบ config หรือพฤติกรรม แม้จะ “อัปเกรดแค่ image”:

| สถานการณ์ | ผลที่อาจเห็น |
|-----------|----------------|
| ลบหรือย้ายโฟลเดอร์บน host ที่เคย mount | ขาด config / runtime — ไม่เกี่ยวกับ image แต่ข้อมูลหายจาก host |
| เปลี่ยน `CONFIG_PATH` / ไม่ mount `deploy/config` เหมือนเดิม | แอปอาจชี้ไป config ว่างหรือคนละไฟล์ |
| อัปเกรดแอปแล้วมี **ฟีเจอร์ใหม่ที่ต้องการฟิลด์ใน master** | ไฟล์เก่ายังอยู่ แต่ต้อง merge ค่าใหม่ (หายาก; มักมีค่า default) |
| ตั้ง env ใน compose ให้ **ทับ** พฤติกรรม (เช่น path ผิด) | พฤติกรรมเปลี่ยนเพราะ env ไม่ใช่เพราะไฟล์ config หาย |

ถ้าปฏิบัติตาม **mount เดิม + ไม่ลบข้อมูลบน host** การอัปเกรด image ตามที่ออกแบบใน repo นี้ **ไม่เขียนทับ** ไฟล์ configuration ที่คุณเก็บบน volume — สิ่งที่เปลี่ยนคือ **เวอร์ชันของโปรแกรมใน container** เท่านั้น

---

## อ้างอิงคำสั่งอัปเกรด image

- `container-run-config.sh --upgrade-latest` — pull `:latest` แล้วสร้าง container ใหม่ (volume เดิมตามที่ตั้ง env/path)
- `docker compose pull && docker compose up -d` — ถ้าใช้ compose และ volume นิยามแบบเดิม

หลังอัปเกรด แนะนำเปิด Setup → Verify หรือรัน `scripts/verify-golive.sh` ตามสภาพแวดล้อม

---

## รีเซ็ตเริ่มใหม่ทั้งหมด (ไม่ให้ชี้ `config-both` / config เก่าอีก)

**ลบแล้วตั้งค่าใหม่ได้** — สิ่งที่ทำให้ยังไปอ้าง `config-both` คือไฟล์บน **host** (`master.config.json` ใน `deploy/config`) ที่บันทึก path เก่าไว้ ไม่ใช่ใน Docker image

ขั้นตอนแนะนำ (Compose / layout มาตรฐาน: `deploy/config` + `runtime`):

1. **หยุด container** (`docker compose down` หรือสคริปต์ที่ใช้)
2. **สำรอง** (ถ้าต้องการ): คัดลอก `deploy/config/` และ `runtime/` ไปที่อื่น
3. **ลบหรือย้ายออก** ไฟล์ที่บังคับใช้ config เก่า:
   - `deploy/config/master.config.json`, `credentials.json` (และ audit/download history ถ้าต้องการเริ่มว่าง)
   - ใต้ **`runtime/.kube`**: ลบ **`config-both`** ถ้าไม่ได้ใช้ merged multi-cluster; ให้เหลือ **`config`** จาก `oc login` บน host (หรือลบทั้งโฟลเดอร์ `.kube` แล้ว login ใหม่)
4. ถ้าใน `.env` เคยล็อก setup ให้ตั้ง **`ALLOW_SETUP_RECONFIGURE=1`** ชั่วคราว
5. **รัน container ใหม่** → เปิด **`/setup.html`** — ค่าเริ่มต้น kubeconfig template คือ `{runtimeRoot}/.kube/config` (อย่าเปลี่ยนเป็น `config-both` เว้นแต่รวมหลาย cluster จริง)
6. บันทึก setup ใหม่ → ไฟล์ master ใหม่จะไม่ชี้ `config-both` โดยอัตโนมัติ

**หมายเหตุ:** แอปไม่สร้างไฟล์ kubeconfig ให้ — คุณควรมี `config` บน host ก่อน หรือเปิด OC auto-login ใน wizard ให้แอปรัน `oc login` เขียนลง path ที่ตั้งไว้

### English: full reset

You **can** wipe and start over. Old `config-both` references come from **persisted** `master.config.json` (and optional legacy `web.config.json`), not from the image. Stop the container, remove or replace `deploy/config/master.config.json` and `credentials.json`, delete `runtime/.kube/config-both` if you do not use a merged kubeconfig, ensure `runtime/.kube/config` exists (via `oc login` on the host), set `ALLOW_SETUP_RECONFIGURE=1` if needed, recreate the container, open `/setup.html`, and save again with the default kubeconfig path `{runtimeRoot}/.kube/config`.

**Password-gated reset (recommended):** With **Portal authentication enabled** in `master.config.json`, open **`/reset-config.html`**, enter admin username/password and the confirmation phrase. This calls `POST /api/setup/reset` (same rules as `GEN_NONINTERACTIVE=1 GEN_MODE=9` + `reset-config-cli.js`). It does **not** run on image upgrade.

---

## English summary

Upgrading the **container image** replaces application binaries and bundled files **inside** the image. Your **bind-mounted** directories on the host (`deploy/config`, `runtime`, optional `.kube` and SSL paths) are **not part of the image**; they persist on disk as long as you keep the same host paths and mount flags. Nothing in this design intentionally wipes those mounts when you pull a newer `ghcr.io/.../kafka_user_mgt` image and recreate the container.

You **do not** need to run first-time setup again after a normal image upgrade — parameters, credentials, bootstrap URLs, and API endpoints in the mounted config **remain in use** until you explicitly reset or delete files. To wipe and re-run setup, use **`/reset-config.html`** (Portal username/password + phrase `RESET_PORTAL_CONFIG`) when Portal auth is enabled, or delete files on the host as described above.
