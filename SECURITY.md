# Security & safe contribution

## Do not commit

Never commit the following to a **public** Git repository:

- **Real IP addresses** or internal hostnames used in production or lab (use placeholders like `your-portal.example.com`, `<API_SERVER_URL>`, `kafka.example.com:443`).
- **Namespaces**, **OpenShift context names**, or **bootstrap server strings** that identify a specific customer estate — use generic examples (`kafka-namespace-dev`, `ocp-context-prod`, `cluster-a`, `cluster-b`).
- **Credentials** — passwords, API tokens, kubeconfig files, TLS private keys, keystores, or `credentials.json` / `master.config.json` with real values.
- **Personally identifiable information (PII)** — real names, employee IDs, email addresses, or machine account names tied to individuals.

Project **examples** should use:

- `example.com`, `example.org`, or RFC 2606-style names.
- Clearly fake users (`example-oc-user`, `admin` only when documented as a placeholder).
- `CHANGE_ME`, `REPLACE_ME`, or hashed placeholders for secrets.

## Repository hygiene

- Follow `.gitignore` — local configs under `deploy/config/` and `webapp/config/` for real secrets are excluded; do not force-add them.
- Avoid “fixed” or “personal” config copies in the repo root (e.g. ad-hoc `*.fixed` files). Use documented `*.example.json` templates instead.

## Reporting

If you believe sensitive data was committed by mistake, **rotate** any exposed credentials immediately and remove the data from history using your organisation’s approved process (e.g. `git filter-repo`) in addition to deleting files in a new commit.
