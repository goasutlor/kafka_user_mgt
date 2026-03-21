# Security

## Dependency and package versions

- **Node**: 18+ (see `package.json` engines). Use a supported LTS version.
- **Express**: Pinned to `^4.22.0` to include fixes for:
  - CVE-2024-29041 (open redirect)
  - CVE-2024-51999 (query prototype)
  - XSS in `res.redirect()`
- Run **`npm audit`** in `webapp/` before release and in CI. Resolve any high/critical findings.
- **Vulnerability assessment (VA):** Run `npm audit` (CVE scan) and `npm outdated` (obsolete packages). As of last VA: 0 vulnerabilities; devDependency `supertest` upgraded to `^7.2.2`. Express 4.x kept (5.x is a major migration); keep Express at `^4.22.0` for security fixes.
- Prefer **exact or minimal ranges** in `package.json` (e.g. `^4.22.0`) and lockfile committed so installs are reproducible.

## Application security measures

- **Security headers**: `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `X-XSS-Protection`, `Referrer-Policy` are set by the server.
- **Input validation**: `username`, `topic`, `systemName`, and each user in remove-list are validated (allowed chars: letters, numbers, `_`, `-`, `.`; max lengths enforced). Passwords/passphrase are length-capped (1024) but not restricted by character set.
- **Path traversal**: Download endpoint `/api/download/:filename` uses `path.basename()` and rejects `..` and mismatched filename.
- **No shell injection from API**: User input is passed to `gen.sh` only via **environment variables** (e.g. `GEN_KAFKA_USER`, `GEN_TOPIC_NAME`). The server never interpolates user input into shell command strings. Ensure `gen.sh` (or your script) only uses these env vars in quoted/controlled ways and never `eval` or unquoted expansion in commands.
- **UI**: All dynamic content rendered in the web UI is escaped with `escapeHtml()` before being set into `innerHTML` to mitigate XSS.

## Config and secrets

- **`web.config.json`** can contain sensitive data:
  - `gen.ocLoginToken` / `gen.ocLoginTokens` (OCP login tokens)
  - `gen.kubeconfigPath` (path to kubeconfig that may be mounted)
- **Do not commit** `web.config.json` that contains real tokens. Prefer:
  - Environment variables: `OC_LOGIN_TOKEN`, `OC_LOGIN_TOKEN_CWDC`, etc. (see server code for names).
  - A copy of config that lives only on the deployment host or in a secret store.
- Use **`web.config.root-example.json`** (or similar) as a template without secrets; document required fields in this file or in deployment docs.

## HTTPS and deployment

- For production, run the server over **HTTPS** (e.g. `server.https` in config or `USE_HTTPS=1` and SSL key/cert paths). Do not rely on plain HTTP for sensitive operations.
- Restrict network access to the app (firewall / network policy) so only trusted clients can reach it.
- If the app is exposed to the internet, consider adding **rate limiting** and **authentication** (e.g. reverse proxy with auth or app-level auth) — not provided by this repo.

## Reporting vulnerabilities

If you find a security issue, please report it privately to the maintainers (e.g. internal channel or security contact) rather than opening a public issue.
