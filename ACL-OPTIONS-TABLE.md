# ACL Options — gen.sh vs Web Portal (CLI Table View)

## 1. gen.sh — Topic ACL (interactive / env)

| Option | GEN_ACL | Topic operations applied        | Description |
|--------|---------|----------------------------------|-------------|
| Read   | 1       | Read, Describe, DescribeConfigs | Consume only |
| Client | 2       | Read, Write, Describe, DescribeConfigs | Produce + Consume + Describe (recommended) |
| All    | 3       | All                              | Full access (Create, Alter, Delete, etc.) |
| Custom | (env)   | GEN_ACL_OPS=Read,Write,...       | Comma-separated list overrides preset |

```
   [1] Read — consume only (Read, Describe, DescribeConfigs)
   [2] Client — Produce + Consume + Describe. Recommended for normal clients; no admin rights.
   [3] All — full access (includes Create, Alter, Delete topic; admin-level).
   Select [1-3] (default: 2):
```

---

## 2. gen.sh — Consumer Group ACL

| Option    | When applied        | Env / logic                    | Description |
|-----------|----------------------|--------------------------------|-------------|
| Read      | Always (auto)        | NEED_CONSUMER_GROUP=true       | Join group, consume. Required for consume/produce. |
| Describe  | Optional             | GEN_ACL_GROUP_EXTRA=Describe   | View group metadata (members, offsets). |
| Delete    | Optional             | GEN_ACL_GROUP_EXTRA=Delete     | Delete the consumer group. |

---

## 3. Web Portal — Topic ACL (dropdown)

| Value   | Label (shown in UI)                                      | Sent to API (acl) | GEN_ACL passed to gen.sh |
|---------|----------------------------------------------------------|--------------------|---------------------------|
| read    | Read — consume only (Read, Describe, DescribeConfigs)     | read               | 1 |
| client  | Client — Produce + Consume + Describe (recommended)     | client             | 2 |
| all     | All — full access (includes Create, Alter, Delete topic) | all                | 3 |

---

## 4. Web Portal — Consumer Group ACL (checkboxes)

| Checkbox        | Sent to API (aclGroupExtra) | GEN_ACL_GROUP_EXTRA passed to gen.sh |
|-----------------|-----------------------------|--------------------------------------|
| (none)          | []                          | (not set)                            |
| Describe ✓      | ["Describe"]                | Describe                             |
| Delete ✓        | ["Delete"]                  | Delete                               |
| Describe + Delete ✓ | ["Describe","Delete"]   | Describe,Delete                       |

Note: Consumer Group **Read** is always added by gen.sh when topic ACL is Read/Client/All (not sent from Web; auto in script).

---

## 5. Kafka ACL operations reference (same in both)

### Topic (--topic &lt;name&gt;)

| Operation      | Description |
|----------------|-------------|
| Read           | Consume messages. Required for consumers. |
| Write          | Produce messages. Required for producers. |
| Describe       | View topic metadata (partitions, offsets). |
| DescribeConfigs| View topic configuration. |
| Create         | Create new topics. Admin-level. |
| Alter          | Alter topic (e.g. add partitions). Admin-level. |
| AlterConfigs   | Change topic config. Admin-level. |
| Delete         | Delete topic. Admin-level. |
| All            | All of the above. |

### Consumer group (--group *)

| Operation | Description |
|-----------|-------------|
| Read      | Join group and consume. **Added by default.** |
| Describe  | View group metadata (members, offsets). Optional. |
| Delete    | Delete the consumer group. Optional. |

---

## 6. Mapping: Web → gen.sh (Add user)

| Web field       | Example value        | Server env              | gen.sh behaviour |
|-----------------|----------------------|-------------------------|------------------|
| acl             | client               | GEN_ACL=2               | Topic: Read,Write,Describe,DescribeConfigs |
| aclGroupExtra   | ["Describe","Delete"]| GEN_ACL_GROUP_EXTRA=Describe,Delete | After group Read, add Describe and Delete on group * |
