# Security Testing — สถานะและมาตรฐานที่ใช้

## สถานะปัจจุบัน: ยังไม่ผ่าน Pentest / VA อย่างเป็นทางการ

โปรเจกต์นี้ **ยังไม่ได้** ผ่านการทำ **Penetration Testing (Pentest)** หรือ **Vulnerability Assessment (VA)** โดยหน่วยงานภายนอกหรือตามมาตรฐานที่ออกใบรับรองได้

สิ่งที่ทำไว้ใน repo คือ **Security-focused unit tests** ในระดับ development เท่านั้น (ใน `webapp/tests/api.test.js`) เช่น

- ตรวจ path traversal, input validation, ขนาด body
- ตรวจ method/route ที่ไม่ควรใช้ได้
- ตรวจว่า response ไม่สะท้อน XSS

สิ่งเหล่านี้ **ไม่เทียบเท่า** กับ:

- การทำ **Pentest** โดยผู้ทดสอบที่ได้รับอนุญาต (authorized penetration test) ต่อระบบที่ deploy จริง
- การทำ **VA** แบบสแกนและประเมินช่องโหว่ตามมาตรฐาน (เช่น OWASP, NIST)
- รายงานหรือใบรับรองจากหน่วยงานที่สาม (third-party)

---

## มาตรฐาน / Framework ที่ใช้กับ Security Test (Pentest & VA)

เวลาจะทำ Security Test อย่างเป็นทางการ หรืออ้างอิงในนโยบาย/ใบรับรอง มักอ้างอิงมาตรฐานหรือ framework เหล่านี้:

### 1. OWASP (Open Web Application Security Project)

| รายการ | คำอธิบาย |
|--------|----------|
| **OWASP Top 10** | รายการช่องโหว่เว็บที่พบบ่อย (A01 Broken Access Control, A02 Cryptographic Failures, A03 Injection ฯลฯ) ใช้เป็น checklist |
| **OWASP Testing Guide** | คู่มือทดสอบความปลอดภัยเว็บ (ทดสอบตามหมวด) |
| **OWASP ASVS** (Application Security Verification Standard) | มาตรฐานตรวจสอบความปลอดภัยแอป (ระดับ L1–L4) ใช้กำหนดขอบเขตและเกณฑ์ผ่าน/ไม่ผ่าน |

- ลิงก์: https://owasp.org/www-project-top-ten/ , https://owasp.org/www-project-web-security-testing-guide/

### 2. PTES (Penetration Testing Execution Standard)

- กำหนดขั้นตอนการทำ Pentest: Pre-engagement, Intelligence Gathering, Threat Modeling, Vulnerability Analysis, Exploitation, Post-Exploitation, Reporting
- ใช้เมื่อจ้างผู้ทำ Pentest ให้ทำตามขั้นตอนที่เป็นมาตรฐาน

- ลิงก์: http://www.pentest-standard.org/

### 3. NIST

| รายการ | คำอธิบาย |
|--------|----------|
| **NIST SP 800-115** | Technical Guide to Information Security Testing and Assessment (แนวทางทดสอบและประเมินความปลอดภัยข้อมูล) |
| **NIST Cybersecurity Framework** | ใช้จัดหมวดการจัดการความเสี่ยงและความปลอดภัย (Identify, Protect, Detect, Respond, Recover) |

- ลิงก์: https://csrc.nist.gov/publications/detail/sp/800-115/final

### 4. อื่นๆ ที่มักอ้างในองค์กร

- **CWE** (Common Weakness Enumeration) — ใช้จัดประเภทช่องโหว่ (เช่น path traversal, injection)
- **CVE** (Common Vulnerabilities and Exposures) — ใช้อ้างอิงช่องโหว่ที่รู้จักแล้ว (โดยเฉพาะ dependency)
- **PCI DSS** — ถ้าเกี่ยวข้องกับการ์ดจ่าย (ต้องทำ Pentest/VA ตามข้อกำหนด PCI)
- **ISO/IEC 27001** — ระบบจัดการความปลอดภัยข้อมูล (ISMS) มักกำหนดให้มีการทดสอบความปลอดภัย/ประเมินความเสี่ยง

---

## การทดสอบใน Repo นี้เทียบกับ OWASP Top 10 (แบบคร่าวๆ)

| OWASP Top 10 (แนวโน้ม) | สิ่งที่ทดสอบใน repo |
|------------------------|----------------------|
| A01 – Broken Access Control | ตรวจ path traversal, การเข้าถึงไฟล์นอกโฟลเดอร์ (download endpoint) |
| A03 – Injection | ยังไม่ครอบคลุม (SQL/command injection ฯลฯ ควรทำใน Pentest/VA) |
| A04 – Insecure Design | ตรวจ validation input, passphrase/confirm |
| A05 – Security Misconfiguration | ไม่ได้สแกน config/server โดยตรง |
| A07 – Identification and Authentication Failures | ตรวจว่า passphrase ต้องมีและตรงกัน (ยังไม่มี auth/login ในแอป) |

สรุป: เป็นเพียง **ส่วนหนึ่ง** ของการป้องกันตามแนว OWASP **ไม่ใช่** การทดสอบครบตาม OWASP Top 10 หรือ ASVS

---

## แนะนำขั้นตอนถ้าต้องการ “ผ่าน Pentest / VA”

1. **กำหนดขอบเขตและมาตรฐาน**  
   เลือกว่าจะอ้างอิงอะไร (เช่น OWASP ASVS L1, NIST SP 800-115, หรือข้อกำหนดหน่วยงาน/ธนาคาร)

2. **ทำ VA ก่อน**  
   - สแกนช่องโหว่ (dependency, OS, web server)  
   - ใช้เครื่องมือเช่น npm audit, Snyk, Trivy (container), หรือ VA scanner ตามมาตรฐานที่องค์กรใช้

3. **ทำ Pentest**  
   - ให้ทีมหรือผู้ให้บริการภายนอกที่ได้รับอนุญาตทดสอบต่อระบบที่ deploy จริง (หรือ staging ที่ใกล้เคียง production)  
   - ทำตาม PTES หรือ scope ที่ตกลง (รวม OWASP Top 10 / ASVS ถ้าต้องการ)

4. **จัดเก็บหลักฐาน**  
   - รายงาน Pentest / VA  
   - แก้ไขช่องโหว่และทดสอบซ้ำจนผ่านเกณฑ์ที่กำหนด

---

## สรุป

- **โปรเจกต์นี้ยังไม่ผ่าน Pentest / VA อย่างเป็นทางการ**  
- มาตรฐานที่มักใช้กับ Security Test ได้แก่ **OWASP** (Top 10, Testing Guide, ASVS), **PTES**, **NIST SP 800-115**, และ CWE/CVE  
- การทดสอบใน repo เป็น **security unit tests** เพื่อลดความเสี่ยงเบื้องต้นเท่านั้น  
- ถ้าต้องการ “ผ่าน Pentest และ VA” ตามมาตรฐาน ต้องดำเนินการ VA และ Pentest กับระบบที่ deploy จริง และอ้างอิงมาตรฐานที่องค์กรหรือหน่วยกำกับกำหนด
