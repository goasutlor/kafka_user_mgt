# แนวทาง Optimize Shell (gen.sh) — Performance + โครงสร้าง

สคริปต์ตอนนี้ส่วนใหญ่รอ I/O (oc, Kafka CLI) ดังนั้นการ optimize เน้น: **ลดการเรียกซ้ำ** และ **ทำ parallel ที่ปลอดภัย**

**แนวทางใช้:** ค่อยทำ optimize gen.sh ทีหลังเพื่อให้ Performance / Latency ดีขึ้น — พอใช้ได้ทั้งรันแบบ **Manual CLI** และแบบ **Web (Backend เรียก gen.sh)** เพราะ logic อยู่ที่เดียว  optimize ที่ gen.sh = ได้ผลทั้งสองทาง

---

## 1. ทำ Parallel ที่ยังทำแบบลำดับอยู่ (ผลชัดที่สุด)

### 1.1 ลบ User (DELETE) — patch ทุก site พร้อมกัน
**ตอนนี้:** วน loop ตาม sites (เช่น site แรก, site ที่สอง) → get secret → jq → patch แบบทีละ site  
**เสนอ:** ดึง secret ทั้งสอง site พร้อมกัน (background) แล้ว patch ทั้งสองพร้อมกัน (เหมือน Add user ที่ทำแล้ว)

- ประหยัดเวลา: ประมาณครึ่งหนึ่งของช่วง patch (จาก 2 เท่าของเวลาต่อ site เหลือ ~เท่าเวลาต่อ 1 site)

### 1.2 เปลี่ยนรหัส (CHANGE_PASSWORD) — patch ทุก site พร้อมกัน
**ตอนนี้:** วน loop patch site แรก แล้วค่อย site ถัดไป  
**เสนอ:** patch สอง site แบบ parallel + verify สอง site แบบ parallel (เหมือน Add user)

### 1.3 Verify หลังลบ User — รันสอง site พร้อมกัน
**ตอนนี้:** วน `for REMOVE_USER` แล้วในแต่ละ user เรียก verify site แรก แล้วค่อย site ถัดไป  
**เสนอ:** ต่อ user รัน verify ทุก site พร้อมกัน (background แล้ว wait) จะได้ไม่ต้องรอ site แรกจบก่อนค่อย site ถัดไป

---

## 2. Cache รายชื่อ User ในเมนู User management (ลด oc get ซ้ำ)

**ตอนนี้:** ทุกครั้งที่เข้าเมนูย่อย (Remove / Change password) แล้วต้องมีรายชื่อ user จะ `oc get secret` จาก site แรก (หรือ merge จากทุก site)  
ถ้าคนใช้กดกลับไปกลับมา หรือมีหลาย action ในรอบเดียว จะดึงซ้ำหลายครั้ง

**เสนอ:**
- ดึงรายชื่อ user **ครั้งเดียว** ตอนเข้า User management (ก่อนแสดงเมนู 1/2/3)
- เก็บในตัวแปร (หรือไฟล์ชั่วคราว) แล้วใช้ซ้ำสำหรับ Remove และ Change password
- **Invalidate (ดึงใหม่)** หลังทำ action ที่เปลี่ยน secret: ลบ user, เปลี่ยนรหัส, หรือกลับไปเมนูหลักแล้วเข้ามาใหม่

ผล: เมนูตอบสนองเร็วขึ้นโดยเฉพาะเมื่อ user เยอะ หรือเครือข่ายช้า

---

## 3. ลด Subprocess (jq + grep)

**ตอนนี้:** แยก `jq -r 'keys[]'` แล้วส่งไป `grep -vE "$SYSTEM_USERS" | sort`  
**เสนอ:** ทำใน jq ตัวเดียว เช่น ใช้ `keys[] | select(test("^(kafka|...)") | not)` แล้ว pipe ไป `sort` (หรือใช้ `jq -r '...' | sort`)  
ลดจำนวน process นิดหน่อย แต่ช่วยเมื่อเรียกบ่อย (เช่น ใน loop หรือเมนู)

---

## 4. โครงสร้างไฟล์ (ลดความ “อ้วน” ของไฟล์เดียว)

**เสนอ:** แยกเป็นไฟล์ที่ใช้ `source` ใน gen.sh

| ไฟล์ | เนื้อหา |
|------|--------|
| `config.sh` หรือค่าตัวแปรด้านบน | BASE_DIR, K8S_SECRET_NAME, NS_*, OCP_CTX_*, BOOTSTRAP_*, TIMEOUT_*, SYSTEM_USERS ฯลฯ |
| `lib.sh` (หรือ `functions.sh`) | ฟังก์ชัน: `validate_username`, `verify_user_in_secret`, `verify_user_absent_from_secret`, `patch_site`, `log_action`, `cleanup_temp_files`, `acquire_lock`, `error_exit`, UI (spinner, status_msg, done_msg), ACL helpers |
| `gen.sh` | source config + lib แล้วเหลือแค่: main loop, เมนู, flow Add/Test/User management (เรียกใช้ฟังก์ชันจาก lib) |

ผล: แก้/อ่านทีละส่วนง่ายขึ้น ไม่ได้เร่งความเร็วโดยตรง แต่ช่วยให้ optimize ต่อได้ง่าย

---

## ลำดับแนะนำ (ถ้าทำทีละขั้น)

1. **Parallel DELETE และ CHANGE_PASSWORD** — ได้ผลเวลาเร็วขึ้นชัดเจน  
2. **Cache รายชื่อ user ใน User management** — ลด oc get ซ้ำ เมนูลื่นขึ้น  
3. **Verify หลังลบ แบบ parallel ต่อ user** — ได้เวลาน้อยลงนิดหน่อย  
4. **jq รวมกับ filter** — เล็กน้อย  
5. **แยก config / lib** — โครงสร้างและ maintain ดีขึ้น

---

## สิ่งที่สคริปต์ทำ parallel อยู่แล้ว (ไม่ต้องเปลี่ยน)

- **Add user:** `patch_site` ทุก site รัน parallel แล้วตามด้วย verify ทุก site แบบ parallel

ถ้าต้องการให้ช่วยลงมือแก้ใน gen.sh ตามข้อ 1–3 (parallel DELETE/CHANGE_PASSWORD + cache user list + verify parallel) บอกได้เลยว่าจะให้ทำถึงข้อไหน
