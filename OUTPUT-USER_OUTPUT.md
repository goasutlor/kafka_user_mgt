# เก็บไฟล์ .enc ไว้ใน user_output/ เท่านั้น

เพื่อไม่ให้ root โฟลเดอร์รก ไฟล์ที่ script สร้าง (.enc, .tar.gz ชั่วคราว) ต้องไปอยู่ที่ **user_output/** เท่านั้น

## 1. สคริปต์บน server (confluent-usermanagement.sh) ต้องมีส่วนนี้

ใกล้ต้นไฟล์ (หลังตัวแปรพื้นฐาน) ต้องมี:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
USER_OUTPUT_DIR="${GEN_USER_OUTPUT_DIR:-$SCRIPT_DIR/user_output}"
mkdir -p "$USER_OUTPUT_DIR"
```

และทุกที่ที่สร้างไฟล์ .enc หรือ tarball ต้องใช้ `$USER_OUTPUT_DIR` ไม่ใช่ current directory เช่น:

```bash
ENC_FILE="${USER_OUTPUT_DIR}/${SYSTEM_NAME}_${TIMESTAMP}.enc"
TARBALL="${USER_OUTPUT_DIR}/${SYSTEM_NAME}_${TIMESTAMP}.tar.gz"
```

และก่อนจบ (non-interactive) ต้อง echo:

```bash
echo "GEN_PACK_DIR=$USER_OUTPUT_DIR"
echo "GEN_PACK_FILE=$(basename "$ENC_FILE")"
```

**ถ้าใช้ gen.sh จาก repo:** มี logic นี้ครบแล้ว ไม่ต้องแก้  
**ถ้าใช้ confluent-usermanagement.sh:** ต้อง sync ส่วน SCRIPT_DIR, USER_OUTPUT_DIR และ path ของ ENC_FILE/TARBALL ให้ตรงกับ gen.sh (หรือ copy จาก gen.sh ไปใช้)

## 2. ย้ายไฟล์ .enc เดิมที่อยู่ที่ root

บน server (ในโฟลเดอร์ kafka-usermgmt):

```bash
mkdir -p user_output
mv *.enc user_output/
```

หรือใช้สคริปต์จาก repo:

```bash
bash /path/to/gen-kafka-user/scripts/move-enc-to-user-output.sh /opt/kafka-usermgmt
```

## 3. โครงสร้างหลังจัดแล้ว

```
/opt/kafka-usermgmt/
├── confluent-usermanagement.sh
├── configs/
├── kafka_2.13-3.6.1/
├── certs/
├── Docker/
├── user_output/          ← เก็บทุกไฟล์ .enc ไว้ที่นี่อย่างเดียว
│   ├── Payment_System_20260224_0523.enc
│   └── ...
├── podman_runconfig.sh
└── ...
```
