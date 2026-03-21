# Error Handling and Critical Operations

This document describes how error handling and critical (destructive) operations work in **gen.sh** and the **Web app**, so you can trace issues in production and understand the “validate first, no partial commit” policy.

---

## 1. Critical operations (gen.sh)

The following are treated as **critical**: they change secrets or ACLs and must be safe for production.

| Operation | What it does | Validation before action | Commit policy |
|-----------|--------------|---------------------------|---------------|
| **Remove user(s) + ACL** | Deletes ACLs then removes users from plain-users.json (ทุก site ตาม gen.sites) | Read both secrets; verify every selected user exists in both; then remove ACLs; then patch both namespaces | If site ถัดไป patch ล้มเหลว **site แรกจะถูก revert** so no partial state |
| **Change password** | Updates one user’s password in plain-users.json (ทุก site ตาม gen.sites) | Read both secrets; verify user exists in both; then patch site แรก แล้ว site ที่สอง | If site ถัดไป patch ล้มเหลว **site แรกจะถูก revert** |
| **Cleanup orphaned ACLs** | Removes ACLs for principals that are no longer in the secret | No secret write; only ACL removal | N/A (no secret commit) |
| **Add user** | Adds user to both secrets, adds ACL, packs .enc | Topic and username validated; duplicate check; then add to both sites and verify | On failure, gen.sh exits before or after patch; script does not partially patch one site only |

---

## 2. Validate-first, no partial commit

- **Validate first:** Before any destructive step, gen.sh checks what it can (e.g. read secrets, user exists in both namespaces). If validation fails, it exits with a clear error and **does not change anything**.
- **No partial commit:** For operations that write to **ทุก site** (ทุก cluster OCP):
  - Patches are applied in a fixed order (site แรก แล้ว site ถัดไป).
  - If the **second** patch fails, the script **reverts the first** (re-applies the original JSON) and then exits with an error. So you never end up with one namespace updated and the other not.

---

## 3. Error handling in gen.sh

- **`error_exit [step_name] message`**  
  Logs to `provisioning.log` (with optional step name), prints a clear message, and exits with code 1. Use step names (e.g. `REMOVE_VALIDATE`, `REMOVE_SECRET`, `CHANGE_PW_VALIDATE`) so logs are easy to grep.

- **Exit code and trap**  
  - Exit 0 = success (or user cancel where applicable).  
  - Exit 1 = error (always via `error_exit`).  
  - On EXIT/INT/TERM, the script runs a trap that logs non-zero exit code to `provisioning.log` and then cleans up temp files and the lock.

- **Where to look when something fails**  
  - Terminal / Web UI: message and optional `[step_name]`.  
  - `provisioning.log`: `action=ERROR | step=...` and `SCRIPT_EXIT | exit_code=1`.

---

## 4. Error handling in the Web app

- **Before calling gen.sh**  
  The server checks that config is loaded and `gen.scriptPath` exists (`validateGenReady()`). If not, it returns 500 with a clear message and does not run gen.sh.

- **After gen.sh returns**  
  - Success: JSON with `ok: true` and operation-specific fields.  
  - Failure: JSON with `ok: false`, `error`, and optional `step`, `phase`, `exitCode`, `stderr`, `stdout` so the UI and logs can show what failed.

- **Logging**  
  Every failed gen.sh run is logged to the server console with route name, status, step/phase, exit code, and a snippet of stderr so production issues are traceable.

- **UI**  
  When an API returns an error, the UI shows the main message and, when present, step, phase, exit code, and a “Details” block (stderr or stdout) so users can trace problems without reading server logs only.

---

## 5. How to trace a problem

1. **Web UI**  
   Check the red error message and the “Details (stderr)” (or stdout) section. Note step/phase and exit code if shown.

2. **Server logs**  
   Look for `[route-name] 500 ... code=1` and the following `[stderr]` lines (e.g. Node process stdout/stderr or your deployment logs).

3. **gen.sh and provisioning.log**  
   - In the script output (or in stderr captured by the server), look for `ERROR [step_name] message`.  
   - In `provisioning.log` (path from `GEN_LOG_FILE` or config), search for `ERROR`, `step=`, and `SCRIPT_EXIT | exit_code=`.

4. **Exit code**  
   - 0 = success.  
   - 1 = error (gen.sh always uses 1 for failures).

---

## 6. Quick reference: gen.sh step names

| Step | Meaning |
|------|--------|
| `REMOVE_VALIDATE` | Pre-check for remove (e.g. cannot read secret or user not in secret). No changes made. |
| `REMOVE_SECRET` | Remove: jq or patch failed; if site ถัดไปล้มเหลว site แรกถูก revert แล้ว |
| `CHANGE_PW_VALIDATE` | Pre-check for change password (e.g. user not in secret). No changes made. |
| `CHANGE_PW_SECRET` | Change password: jq or patch failed; if site ถัดไปล้มเหลว site แรกถูก revert แล้ว |

These step names are written to stderr and to `provisioning.log` so you can correlate Web responses with gen.sh behavior.
