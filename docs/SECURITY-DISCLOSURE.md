# Security vulnerability disclosure

**Last updated:** 2026-09-05

← [Project home](../README.md#contact)

Report **security vulnerabilities** in this kit (scripts, compose defaults, leak paths) — not general VPN support.

---

## How to report

| Channel | Use |
|---------|-----|
| **Telegram** | [@amnezia_reality_kit](https://t.me/amnezia_reality_kit) — message starts with **`[security]`** |

**Do not** open public GitHub issues for exploitable findings until we acknowledge.

---

## Please include

- Affected component (host scripts, container, `.env` / template, default port bind, etc.)
- Steps to reproduce on a typical IN install
- Impact (confidentiality / integrity / availability)
- Your kit version or commit hash

---

## What we will do

1. Acknowledge within a reasonable window (best effort; no SLA).
2. Confirm or decline the report.
3. Coordinate fix and release; credit if you want it.

---

## Out of scope

- Misconfiguration of **your** `.data/.env` or host nginx (operator docs: [QUICKSTART](./QUICKSTART.md))
- Upstream only: AmneziaWG app, Xray-core, Teleproxy — report to those projects
- DNS leak **audit / hardening** (not vulnerability reports): [SECURITY.md](./SECURITY.md)

→ [All documentation](./README.md)
