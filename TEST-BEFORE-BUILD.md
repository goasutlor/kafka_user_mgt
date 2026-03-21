# เทสธรรมดาก่อน Build

เพื่อไม่ต้อง build image หลายรอบ แนะนำให้ **เทสบนเครื่องก่อน** แล้วค่อย build/deploy

## วิธีเทส (ไม่ต้อง Build image)

1. **รัน Backend (Node)**  
   ในโฟลเดอร์ `webapp`:
   ```bash
   cd webapp
   npm start
   ```
   หรือถ้าอยู่ที่ root โปรเจกต์:
   ```bash
   node webapp/server/index.js
   ```
   (ต้องมี `webapp/config/web.config.json` และ path ใน config ต้องใช้ได้บนเครื่องนี้)

2. **เปิด Web UI**  
   - ถ้า server ใช้ HTTPS + port 3443: เปิดเบราว์เซอร์ไปที่ `https://localhost:3443`  
   - หรือดูใน log ว่า server ฟังที่ URL ไหน

3. **ทดสอบ flow**  
   - Add user, Test user, Remove, Change password, Cleanup  
   - กด **Cancel** ได้ระหว่างรอ  
   - หลัง Add user สำเร็จ ลองดาวน์โหลด .enc

4. **เทสอัตโนมัติ (ไม่ต้องเปิด browser)**  
   ```bash
   cd webapp
   npm test
   ```

เมื่อเทสผ่านแล้วค่อย **build image** และ deploy ครับ
