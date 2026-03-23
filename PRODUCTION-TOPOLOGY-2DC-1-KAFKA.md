# Production: 2 DC + Kafka cluster เดียว (Confluent) — การใช้สคริปต์/Portal นี้

เอกสารนี้สรุปว่า **ใช้ได้หรือไม่**, **แมปกับโมเดลในโปรเจกต์อย่างไร**, และ **ข้อควรระวัง** เมื่อต้องการให้เป็น **เครื่องมือกลาง (universal)** หลาย Kafka environment

---

## สรุปสั้น (Executive)

| คำถาม | คำตอบ |
|--------|--------|
| ใช้ Production ได้ไหม ถ้า **2 DC (สอง OpenShift / สอง region)** แต่ **Kafka cluster เดียว (Confluent)** | **ได้** — ถ้าโมเดลตรงกับที่โปรเจกต์ออกแบบ: **หนึ่ง logical cluster**, **หลาย OCP site** (แต่ละที่มี namespace + secret `plain-users.json` ที่ต้อง sync กัน) |
| เป็น Universal สำหรับทุก Kafka env ได้ไหม | **ได้ในระดับ “หนึ่ง deployment ต่อหนึ่งชุด config/runtime”** — สลับ environment ผ่าน `environments.json` + session ได้ **ภายใน cluster/ทีมเดียวกัน**; **ไม่ใช่** multi-tenant SaaS แยกลูกค้าโดยอัตโนมัติโดยไม่จัดการ config/สิทธิ์แยก |

---

## โมเดลที่สคริปต์/Portal รองรับอยู่แล้ว

- **หลาย OCP context / หลาย namespace** (เช่น DC-A และ DC-B) แต่ละที่มี Confluent/Kafka operand และ **secret เดียวกันในเชิงบทบาท** (เช่น `kafka-server-side-credentials` + key `plain-users.json`)
- **`gen.sh` / Web API** จะ **วนทุก site** ที่ตั้งใน `GEN_OCP_SITES` / `fallbackSites` / `environments.*.sites` — **อ่าน/แก้ secret + ACL ให้ครบ** ก่อนถือว่าสำเร็จ; ถ้า patch ข้างหลังล้มเหลวมีแนวคิด **revert site ก่อนหน้า** (ดู `ERROR_HANDLING_AND_CRITICAL_OPS.md`)
- **Bootstrap Kafka** มักเป็น **สตริงเดียว** ที่รวม broker หลายตัว (หรือ VIP) — โปรเจกต์รองรับ **bootstrap ต่อ environment** ผ่าน `environments.json` เมื่อสลับ env บน Portal

นี่สอดคล้องกับ **“2 DC, single Confluent Kafka cluster”** ในแง่ที่ **control plane เป็น 2 ที่ (OCP)** แต่ **ข้อมูล user SASL/plain** ต้อง **สอดคล้องกันทั้งสองฝั่ง** (สิ่งที่สคริปต์ช่วย enforce)

---

## เงื่อนไข Production ที่ต้องผ่าน (ไม่ใช่แค่ “รันได้”)

1. **เครือข่าย** — เครื่องที่รัน container/Node ต้องถึง **API OCP ทุก DC** และ **Kafka bootstrap** ที่ใช้ใน admin/client properties (timeout, firewall, MTLS ตามจริง)
2. **Kubeconfig** — ไฟล์เดียว (หรือ merge แล้ว) มี **context ครบทุกชื่อ** ที่ใส่ใน `ocContext` และ token/สิทธิ์ **get/patch secret** ใน namespace ที่เกี่ยวข้อง
3. **ความสอดคล้องของ secret** — ทั้งสอง DC ต้องใช้ **แนวทางเดียวกัน** ว่า user list อยู่ secret ไหน / key ไหน; ถ้าฝั่งหนึ่ง customize ชื่อ secret ต้องตั้งใน config ให้ตรงทุก site
4. **Kafka admin สิทธิ์** — `kafka-acls` / `kafka-topics` ใช้บัญชีที่มีสิทธิ์จริงบน cluster เดียวนั้น (ไม่แยก “admin ต่อ DC” ในเชิง Kafka ถ้าเป็น cluster เดียว)
5. **ความพร้อมของ DC เดียว** — ถ้า **OCP ข้างหนึ่งล่ม** การ add/remove user อาจ **ล้มทั้ง flow** หรือเหลือครึ่งหนึ่ง — ต้องมี **รันbook** (retry, maintenance window, หรือยอมรับว่า ops บางอย่างทำไม่จบจนกว่า DC กลับ)

---

## ข้อจำกัดเมื่อต้องการ “Universal ทุก Kafka env”

- **หนึ่ง process / หนึ่งชุด mount** มัก = **หนึ่ง `runtimeRoot` + หนึ่งชุด `.properties` + หนึ่ง kubeconfig tree** ที่ container เห็น — การเป็น universal ใน repo นี้คือ **หลาย logical environment ใน config เดียว** (`environments.json`, สลับบน UI) **ไม่ใช่** แทนที่จะรวมทุกบริษัท/ทุก cluster โลกใน instance เดียวโดยไม่แยก secret file
- **ความเสี่ยงด้าน security** — Portal ที่แตะทั้ง OCP และ Kafka admin ควรอยู่หลัง **auth**, **TLS**, **network จำกัด**, audit log — ดู `SECURITY.md` / checklist deploy
- **เวอร์ชัน Confluent / Kafka** — CLI ใน image มีเวอร์ชันหนึ่ง; cluster เก่ามาก/ใหม่มากอาจต้องปรับ `clientInstallDir` หรือ build image ให้ตรงนโยบาย

---

## แนะนำก่อนขึ้น Production (2 DC + cluster เดียว)

1. รัน **`scripts/verify-golive.sh`** + **`scripts/check-deployment.sh`** + E2E จริง (`scripts/check-e2e.sh`) บน environment ที่ใกล้ prod
2. ทดสอบ **ปิดจำลอง DC หนึ่ง** (block API) แล้วดูพฤติกรรม add/remove user ว่ายอมรับได้หรือไม่
3. สำรอง **kubeconfig + master.config + credentials** ตามนโยบาย (ไม่ commit ลง git)
4. กำหนด **ใครเป็น owner** ของ “universal” instance — ทีมเดียว vs แยก instance ต่อ domain

---

## English summary

This stack is **suitable for production** in a **two-DC (dual OpenShift) deployment** that still presents a **single logical Confluent/Kafka cluster**, as long as you configure **one site row per DC** (context + namespace), use a **consistent secret name/key** for `plain-users.json`, and ensure **network + RBAC + kubeconfig** cover every site. It is **“universal” within one deployment** via multi-environment JSON and UI switching—not a substitute for **hard multi-tenant isolation** without separate configs, credentials, and governance per estate.
