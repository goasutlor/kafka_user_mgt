# Kafka ACL Permission UI — Cursor Context

## ภาพรวมโปรเจค

สร้าง Web UI สำหรับจัดการ **Permission (ACL)** ของ Kafka User แบบ SASL_PLAIN
ใช้แทนหน้า "3. Permission" ในระบบ Confluent Kafka User Management เดิม ซึ่งให้ตัวเลือกหยาบเกินไป
UI ใหม่ต้องให้ admin เลือก ACL ได้ละเอียดในระดับ Resource + Operation + PatternType

---

## Stack & Constraints

- Framework: React (หรือ HTML/CSS/JS ถ้าไม่มี React)
- Styling: Tailwind CSS หรือ CSS Variables (ห้ามใช้ inline style สำหรับ layout หลัก)
- ไม่มี backend ใน scope นี้ — UI ทำหน้าที่ **สร้าง Command String** ที่ Backend จะเอาไป execute ผ่าน `kafka-acls.sh`
- Form ห้ามใช้ `<form>` tag ให้ใช้ onClick / onChange แทน
- รองรับ Dark mode ผ่าน CSS variables

---

## โครงสร้าง UI ที่ต้องการ (3 ส่วนหลัก)

### ส่วนที่ 1 — Role Template Selector

แสดงเป็น **Card Grid** (3 columns) ให้ user คลิกเลือก role ก่อน
เมื่อเลือกแล้วให้ auto-populate ส่วนที่ 2 และ 3

Role ที่ต้องมีทั้งหมด 8 รายการ:

| Role Key | ชื่อแสดง | Badge | คำอธิบาย |
|---|---|---|---|
| `producer` | Producer | Write only | Service ที่ยิงข้อมูลเข้า topic เท่านั้น |
| `consumer` | Consumer | Read only | Service ที่รับข้อมูลผ่าน consumer group — **ใช้บ่อยที่สุด** |
| `prosumer` | Prosumer | Read + Write | Stream processor ที่อ่านและเขียน |
| `idempotent` | Idempotent Producer | Write + Txn | Producer ที่ต้องการ exactly-once |
| `monitor` | Monitor / Audit | Read-meta only | Observability tools, Kafka UI |
| `connector` | Kafka Connect | Read + Write + Internal | Source/Sink connector |
| `streams` | Kafka Streams App | Write + Create + Group | ต้องสร้าง internal topics |
| `admin` | Topic Admin | Full topic admin | DevOps/Platform team เท่านั้น |

**card `consumer` ต้องมี highlighted border** (เพราะเป็น role ที่ client ทั่วไปใช้มากที่สุด) และมี badge "ใช้บ่อยที่สุด"

---

### ส่วนที่ 2 — ACL Detail (auto-populate จาก role ที่เลือก แต่ user แก้ได้)

แสดงเป็น **Resource Section** แยกกัน แต่ละ section มี:
- Resource Type label (TOPIC / GROUP / CLUSTER / TRANSACTIONAL_ID)
- Resource Name input (text field)
- Pattern Type dropdown: `LITERAL` | `PREFIXED`
- Operation checkboxes — แสดงทุก operation ที่ available สำหรับ resource นั้น พร้อม badge และคำอธิบายสั้น

#### Operations ที่ต้องมีแยกตาม Resource Type

**TOPIC:**
| Operation | Badge | คำอธิบาย |
|---|---|---|
| READ | read | Consume messages จาก topic |
| WRITE | write | Produce messages เข้า topic |
| DESCRIBE | read | ดู partition, offset, leader info |
| DESCRIBE_CONFIGS | read | อ่าน topic config เช่น retention.ms |
| CREATE | admin | สร้าง topic ใหม่ |
| DELETE | admin | ลบ topic |
| ALTER | admin | เปลี่ยน partition count |
| ALTER_CONFIGS | admin | เปลี่ยน retention, replication config |

**GROUP:**
| Operation | Badge | คำอธิบาย |
|---|---|---|
| READ | read | Join consumer group, commit offset |
| DESCRIBE | read | ดู lag, members, offset ของ group |
| DELETE | admin | ลบ consumer group หรือ reset offset |

**CLUSTER:**
| Operation | Badge | คำอธิบาย |
|---|---|---|
| DESCRIBE | read | ดู broker info, cluster metadata |
| IDEMPOTENT_WRITE | write | เปิดใช้ idempotent producer |
| CREATE | admin | สร้าง topic ระดับ cluster |
| ALTER | admin | เปลี่ยน broker config |
| CLUSTER_ACTION | admin | Replica fetch, reassignment |
| DESCRIBE_CONFIGS | read | อ่าน broker-level config |

**TRANSACTIONAL_ID:**
| Operation | Badge | คำอธิบาย |
|---|---|---|
| WRITE | write | ใช้ transactional producer |
| DESCRIBE | read | ดู transaction state |

#### Default ACL per Role

```js
const ROLE_DEFAULTS = {
  producer: {
    resources: [
      {
        type: "topic",
        name: "your-topic",
        pattern: "LITERAL",
        ops: ["WRITE", "DESCRIBE"]
      }
    ]
  },
  consumer: {
    resources: [
      {
        type: "topic",
        name: "your-topic",
        pattern: "LITERAL",
        ops: ["READ", "DESCRIBE"]
      },
      {
        type: "group",
        name: "your-consumer-group",   // ห้ามใช้ * — ต้องระบุชื่อจริง
        pattern: "LITERAL",
        ops: ["READ", "DESCRIBE"]
      }
    ]
  },
  prosumer: {
    resources: [
      {
        type: "topic",
        name: "input-topic",
        pattern: "LITERAL",
        ops: ["READ", "DESCRIBE"]
      },
      {
        type: "topic",
        name: "output-topic",
        pattern: "LITERAL",
        ops: ["WRITE", "DESCRIBE"]
      },
      {
        type: "group",
        name: "your-consumer-group",
        pattern: "LITERAL",
        ops: ["READ", "DESCRIBE"]
      }
    ]
  },
  idempotent: {
    resources: [
      {
        type: "topic",
        name: "your-topic",
        pattern: "LITERAL",
        ops: ["WRITE", "DESCRIBE"]
      },
      {
        type: "cluster",
        name: "kafka-cluster",
        pattern: "LITERAL",
        ops: ["IDEMPOTENT_WRITE"]
      }
    ]
  },
  monitor: {
    resources: [
      {
        type: "topic",
        name: "*",
        pattern: "LITERAL",
        ops: ["DESCRIBE", "DESCRIBE_CONFIGS"]
      },
      {
        type: "group",
        name: "*",
        pattern: "LITERAL",
        ops: ["DESCRIBE"]
      },
      {
        type: "cluster",
        name: "kafka-cluster",
        pattern: "LITERAL",
        ops: ["DESCRIBE", "DESCRIBE_CONFIGS"]
      }
    ]
  },
  connector: {
    resources: [
      {
        type: "topic",
        name: "your-topic",
        pattern: "LITERAL",
        ops: ["READ", "WRITE", "DESCRIBE"]
      },
      {
        type: "topic",
        name: "connect-",
        pattern: "PREFIXED",
        ops: ["READ", "WRITE", "CREATE", "DESCRIBE"]
      },
      {
        type: "group",
        name: "connect-cluster",
        pattern: "LITERAL",
        ops: ["READ", "DESCRIBE"]
      },
      {
        type: "cluster",
        name: "kafka-cluster",
        pattern: "LITERAL",
        ops: ["DESCRIBE", "CREATE"]
      }
    ]
  },
  streams: {
    resources: [
      {
        type: "topic",
        name: "input-topic",
        pattern: "LITERAL",
        ops: ["READ", "DESCRIBE"]
      },
      {
        type: "topic",
        name: "output-topic",
        pattern: "LITERAL",
        ops: ["WRITE", "DESCRIBE"]
      },
      {
        type: "topic",
        name: "app-id-",
        pattern: "PREFIXED",
        ops: ["READ", "WRITE", "CREATE", "DELETE", "DESCRIBE"]
      },
      {
        type: "group",
        name: "app-id-",
        pattern: "PREFIXED",
        ops: ["READ", "DESCRIBE"]
      }
    ]
  },
  admin: {
    resources: [
      {
        type: "topic",
        name: "your-topic",
        pattern: "LITERAL",
        ops: ["CREATE", "DELETE", "ALTER", "ALTER_CONFIGS", "DESCRIBE", "DESCRIBE_CONFIGS"]
      },
      {
        type: "group",
        name: "*",
        pattern: "LITERAL",
        ops: ["DELETE", "DESCRIBE"]
      },
      {
        type: "cluster",
        name: "kafka-cluster",
        pattern: "LITERAL",
        ops: ["DESCRIBE", "DESCRIBE_CONFIGS"]
      }
    ]
  }
}
```

---

### ส่วนที่ 3 — Generated Command Preview

แสดง `kafka-acls.sh` command ที่ถูก generate แบบ real-time เมื่อ user แก้ไขส่วนที่ 2

#### Format ของ command ที่ต้อง generate

```bash
kafka-acls.sh \
  --bootstrap-server {bootstrapServer} \
  --command-config client.properties \
  --add \
  --allow-principal User:{username} \
  --operation {OP1} \
  --operation {OP2} \
  --{resource-flag} {resourceName} \
  --resource-pattern-type {LITERAL|PREFIXED}
```

**resource-flag mapping:**
- `topic` → `--topic`
- `group` → `--group`
- `cluster` → `--cluster` (ไม่ต้องมี resource name)
- `transactional-id` → `--transactional-id`

แต่ละ resource section generate เป็น command แยกกัน คั่นด้วย blank line

ต้องมีปุ่ม **Copy** สำหรับ copy command ทั้งหมดได้ในคลิกเดียว

---

## Identity Fields (อยู่เหนือ Role Selector)

```
Principal (username):  [input text]          default: ""
Bootstrap Server:      [input text]          default: "localhost:9092"
Permission Type:       [ALLOW | DENY]        default: ALLOW
Host:                  [input text]          default: "*"
```

---

## Warning Rules (แสดง inline warning ในกรณีต่อไปนี้)

| เงื่อนไข | Warning message |
|---|---|
| GROUP resource name = `*` และ role ไม่ใช่ `monitor` หรือ `admin` | "ควรระบุชื่อ consumer group จริงๆ แทน * เพื่อป้องกัน rogue consumer" |
| role = `admin` | "Admin ACL ควรให้เฉพาะ platform/devops team เท่านั้น อย่าให้กับ application service" |
| role = `idempotent` และไม่มี CLUSTER:IDEMPOTENT_WRITE | "Idempotent producer ต้องการ CLUSTER:IDEMPOTENT_WRITE หรือ producer จะ error ตอน startup" |
| TOPIC resource name เป็น empty string | "กรุณาระบุชื่อ topic" |

---

## UX Rules ที่สำคัญ

1. เมื่อคลิกเลือก role ใหม่ → reset ส่วนที่ 2 ตาม `ROLE_DEFAULTS` ทันที
2. User สามารถ **เพิ่ม resource section** ได้เอง (ปุ่ม "+ Add resource")
3. User สามารถ **ลบ resource section** ได้ (ปุ่ม × บน section)
4. Operation checkbox toggle → command preview อัปเดต real-time
5. ห้าม submit ถ้า `principal` ว่าง — แสดง inline error
6. Checkbox ที่ไม่ได้ tick ให้แสดง grayed out พร้อม strikethrough เพื่อให้เห็นว่า operation นั้นมีอยู่แต่ไม่ได้ใช้

---

## Design Direction

- **Tone:** Industrial / Utilitarian — เหมือน developer tool จริงๆ ไม่ใช่ marketing page
- **สีหลัก:** Neutral dark surface, accent สีน้ำเงิน (#378ADD หรือใกล้เคียง)
- **Typography:** Monospace font สำหรับ resource name, operation, และ command preview — Sans-serif สำหรับ label และคำอธิบาย
- **Badge สี:**
  - `read` operations → สีน้ำเงิน (info)
  - `write` operations → สีส้ม/amber (warning)
  - `admin` operations → สีแดง (danger)
- **Command preview block:** dark background, monospace, syntax-highlight ง่ายๆ (flag สีต่างจาก value)
- **Card ที่ถูก select:** highlighted border 2px สีน้ำเงิน + background tint เล็กน้อย
- **Card `consumer`:** มี "ใช้บ่อยที่สุด" badge แสดงตลอดเวลา

---

## Component Structure แนะนำ

```
<KafkaACLPermission>
  ├── <IdentityFields />              // principal, bootstrap, permission, host
  ├── <RoleSelector />                // 8 role cards, click to select
  ├── <ResourceList>                  // dynamic list of resource sections
  │     └── <ResourceSection />      // type, name, pattern, op checkboxes × n
  ├── <WarningBanner />               // conditional warnings
  └── <CommandPreview />             // generated command + copy button
```

---

## ตัวอย่าง Output ที่ถูกต้อง

เมื่อเลือก role `consumer`, principal = `ko007`, topic = `Kotest001`, group = `ko007-cg`:

```bash
kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --command-config client.properties \
  --add \
  --allow-principal User:ko007 \
  --operation READ \
  --operation DESCRIBE \
  --topic Kotest001 \
  --resource-pattern-type LITERAL

kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --command-config client.properties \
  --add \
  --allow-principal User:ko007 \
  --operation READ \
  --operation DESCRIBE \
  --group ko007-cg \
  --resource-pattern-type LITERAL
```
