# Test Report — Functional & Unit Tests (2+2 Rounds)

**วันที่:** 2025-02-18  
**โปรเจกต์:** gen-kafka-user (Web UI for Confluent Kafka User Management)  
**Test suite:** `webapp/tests/api.test.js` (Node.js `node:test` + supertest)

---

## 1. สรุปผลการทดสอบ

| รอบ | ชุดเทส | จำนวนเทส | ผ่าน | ล้มเหลว | Flaky | เวลารวม (โดยประมาณ) |
|-----|--------|-----------|------|---------|-------|----------------------|
| 1   | Unit/API | 30 | 30 | 0 | 0 | ~3.4 s |
| 2   | Unit/API | 30 | 30 | 0 | 0 | ~4.2 s |
| 3   | Unit/API + Reports/Auth | 34 | 34 | 0 | 0 | ~2.8 s |
| 4   | Unit/API + Reports/Auth | 34 | 34 | 0 | 0 | ~3.3 s |

- **รวม:** รันทั้งหมด 4 รอบ ไม่มีเทสใดล้มเหลวหรือ flaky
- หลังรอบ 2 ได้เพิ่ม Unit Test สำหรับ API ใหม่ (audit-log, download-history, login-challenge) แล้วรันอีก 2 รอบ (รอบ 3–4) เพื่อยืนยัน

---

## 2. สิ่งที่ทดสอบ

### 2.1 Config & โหลด config
- มีไฟล์ `web.config.json` และมี `config.gen`, `config.server`
- `loadConfig()` โหลด config ได้ถูกต้อง

### 2.2 API หลัก (Add user, Test user, Remove user, Change password)
- **POST /api/add-user:** validation (ไม่มี body, ขาด systemName/topic/username/passphrase/confirmPassphrase, passphrase ไม่ตรง) → 400
- body ถูกต้อง (passphrase ตรง) → 200 หรือ 500 (ขึ้นกับ gen.sh)
- **POST /api/test-user:** ไม่มี username/password → 400
- **POST /api/remove-user:** ไม่มี `users` → 400
- **POST /api/change-password:** ไม่มี username/newPassword → 400

### 2.3 Helpers
- `parsePackFromStdout` ดึง GEN_PACK_FILE, GEN_PACK_NAME (และ derive packName จาก packFile)
- `buildDecryptInstructions` ให้รูปแบบคำสั่ง decrypt ตรงกับ gen.sh

### 2.4 Security: Download endpoint
- Path traversal (query param, encoded path, backslash) → 400
- ไฟล์ไม่มีอยู่ → 404
- ชื่อไฟล์ว่าง → 400 หรือ 404
- ชื่อยาวมาก / มีแต่ dots/slashes / double dot ใน path → 400 หรือ 404

### 2.5 Security: Input & limit
- passphrase เป็น number → reject หรือ coerce
- XSS ใน systemName → ไม่ reflect เป็น HTML ใน response
- body ขนาด > 256KB → 413 หรือถูก reject

### 2.6 Security: Method & route
- PUT /api/add-user, GET /api/add-user → 404
- POST /api/download/... → 404

### 2.7 API ใหม่ (Reports & Auth) — เพิ่มในรอบ 3–4
- **GET /api/audit-log:** 200, `ok: true`, `entries` เป็น array
- **GET /api/audit-log?from=&to=:** 200, รองรับ query params
- **GET /api/download-history:** 200, `ok: true`, `days` array, `byDay` object
- **GET /api/login-challenge:** 200, `code` เป็น string

---

## 3. สิ่งที่ผิดพลาด / ตกหล่น

- **ไม่มี:** ไม่พบเทสที่ล้มเหลวหรือ flaky ใน 4 รอบ
- **หมายเหตุ:** บน Windows test config ใช้ `dummy-gen.sh` → `spawn sh ENOENT` ได้ 500 สำหรับ add-user แบบมี body ถูกต้อง; เทสยอมรับทั้ง 200 และ 500 อยู่แล้ว จึงถือว่าผ่าน

---

## 4. Functional test (เทสกับ server จริง)

- **test:api:** `npm run test:api` (= `node scripts/test-apis.js`) ออกแบบให้รันกับ **server ที่รันอยู่แล้ว** (เช่น `npm start` แล้วเรียกจากเครื่องอื่นหรือ localhost)
- **ในรอบนี้:** ไม่ได้รัน functional test กับ server จริง (ต้อง start server แยก)
- **วิธีรันเมื่อต้องการ:**  
  `npm start` (ใน terminal แรก) → จากนั้น `node scripts/test-apis.js` หรือ `BASE_URL=http://localhost:3000 node scripts/test-apis.js`

---

## 5. ข้อเสนอแนะ

1. **Unit test ปัจจุบัน:** ครอบคลุม config, add-user/test-user/remove-user/change-password, download security, input validation, และ API audit-log, download-history, login-challenge แล้ว — แนะให้รัน `npm run test` ก่อน deploy หรือก่อน merge
2. **Functional (test:api):** ถ้าต้องการยืนยันทุก endpoint กับ server จริง แนะให้รัน `test:api` หลัง start server (ใน CI อาจใช้ script start server ชั่วคราวแล้วรัน test-apis.js)
3. **เทสเพิ่มเติม (ถ้าต้องการ):**
   - POST /api/login (กับ securityCode จาก login-challenge) เมื่อเปิด auth
   - GET /api/me, GET /api/logout, GET /api/auth-mode
   - การที่ audit-log / download-history ถูก middleware auth บล็อกเมื่อเปิด auth (ถ้ามีพฤติกรรมแบบนั้น)

---

## 6. สรุปท้ายรายงาน

- รัน **Unit/API test 4 รอบ** (2 รอบแรก 30 เทส, 2 รอบหลัง 34 เทส หลังเพิ่มเทส audit-log, download-history, login-challenge)
- **ผล: ผ่านทั้งหมดทุกรอบ ไม่มี fail หรือ flaky**
- เพิ่ม Unit Test สำหรับ **GET /api/audit-log**, **GET /api/download-history**, **GET /api/login-challenge** แล้ว
- Functional test กับ server จริง (`test:api`) ยังไม่ได้รันในรอบนี้; แนะให้รันแยกเมื่อต้องการยืนยันกับ server ที่รันอยู่
