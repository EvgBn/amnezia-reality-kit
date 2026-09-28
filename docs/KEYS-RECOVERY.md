# AWG keys — facts, recovery, verification

**Last updated:** 2026-09-04  
**Scope:** AmneziaWG server keypair (`.data/.env`, `awg0.conf`, client exports)

**SSOT:** AWG server keys live only in `.data/.env`. `make build` renders them into `awg0.conf`. There is no `.data/keys/` mirror — it was removed because private/public files could drift from `.env` and mislead recovery.

**Documentation convention:** WireGuard/AWG key material below uses placeholders (`<AWG_SERVER_PRIVATE_KEY>`, `<AWG_SERVER_PUBLIC_KEY>`) or truncated excerpts (`<correct-priv>…`). Never paste production keys into git-tracked docs.

---

## Incident fact (2026-08-31, example-host)

After a fresh `git clone` + restore of `.data/` from a tmp copy, **AWG clients could not connect** while `make check` reported **51 OK**.

Root cause was **not** port, obfuscation, or missing peers — it was **mismatched server public keys** between runtime and client `.conf` files.

### What existed on disk at the same time (three different stories)

| Source | Server private (excerpt) | Server public | Matches clients? |
|--------|---------------------------|---------------|------------------|
| `.data/.env` (before fix) | `<wrong-priv-a>…` | `<wrong-pub-a>…` | **No** |
| `.data/keys/server_private.key` (removed mirror) | `<wrong-priv-b>…` | — | **No** (see below) |
| `.data/keys/server_public.key` (removed mirror) | — | `<client-pub>…` | Clients **reference** this |
| All four `.data/clients_awg/*.conf` `[Peer] PublicKey` | — | `<client-pub>…` | — |
| **Correct pair** (found in `.data/build-snapshots/pre-env-refactor-20260830-1803/.env`) | `<correct-priv>…` | `<client-pub>…` | **Yes** |

**Critical detail:** the old `keys/server_private.key` and `keys/server_public.key` mirror (since removed) were **not a valid WireGuard pair**.

```text
<wrong-priv-b>…  →  awg pubkey  →  <derived-pub>…
<client-pub>…  (file server_public.key + all client exports)
```

Trusting a `keys/` mirror alone and copying `server_private.key` into `.env` **does not** restore client connectivity if that private key does not derive to the public key in client configs.

### Failed rollback attempt (what did not work)

Planned “variant B”: set `.env` from `keys/server_*.key` mirror files, then **`make refresh-full`**.

| Step | Result |
|------|--------|
| `sed` with two `-i` flags | Works only as **one** `-i` with multiple `-e` expressions |
| `sed` replacing `AWG_SERVER_PUBLIC_KEY=…<base64-with-slash>/…` | **Fails** — `/` inside base64 breaks `s///` delimiter |
| Rollback to `<wrong-priv-b>…` private | Runtime pubkey became `<derived-pub>…` — still **≠** client `<client-pub>` |
| `make check` | Still **51 OK** — preflight does **not** compare container pubkey to client exports |

Additional blockers encountered during recovery:

| Problem | Fix |
|---------|-----|
| `.data/.env` missing | Restore from backup / tmp copy / `COPY_FROM` |
| Repo files deleted (`Makefile`, `render-config.sh`, …) | `git restore --source=HEAD --worktree .` |
| `.data/build/awg0.conf` missing peers | `make build` merges peers from latest `.data/build-snapshots/pre-build-*/awg0.conf` |

### Successful fix (correct sequence)

1. Restore `.data/.env` if missing (from backup or known-good copy).
2. **Find** the private key whose `awg pubkey` equals client `[Peer] PublicKey` (see [Find matching private key](#find-matching-private-key-for-existing-clients) below).  
   On example-host the matching private key was found in `.data/build-snapshots/pre-env-refactor-20260830-1803/.env` (truncated: `<correct-priv>…` → public `<client-pub>…`).
3. Set **both** in `.data/.env` (use a safe editor or Python — not naive `sed` on base64):

   ```bash
   AWG_SERVER_PRIVATE_KEY=<AWG_SERVER_PRIVATE_KEY>
   AWG_SERVER_PUBLIC_KEY=<AWG_SERVER_PUBLIC_KEY>
   ```

   Use the **exact** values from the MATCH step or your verified backup — not these placeholders.

4. Regenerate and reload:

   ```bash
   make refresh-full
   ```

5. **Verify** (must match before declaring fixed):

   ```bash
   echo "runtime: $(docker exec vpn-amneziawg awg show awg0 public-key)"
   echo "client:  $(grep '^PublicKey' .data/clients_awg/evg.conf | awk '{print $3}')"
   ```

   Expected after a successful fix (both lines **identical**, value = client `[Peer] PublicKey`):

   ```text
   runtime: <AWG_SERVER_PUBLIC_KEY>
   client:  <AWG_SERVER_PUBLIC_KEY>
   ```

6. `make check` — stack health only; **always run step 5** after key changes.

---

## FAQ: I accidentally deleted keys / `.env` — how do I restore?

### Minimum to recover **without** re-issuing client configs

You need **the same server keypair** that was embedded in client `[Peer] PublicKey` when exports were created.

**Priority order:**

1. **Off-server backup** — `tar` from [OPERATIONS.md § Backup](./OPERATIONS.md) (`.data/.env`, `clients_awg/`, `build/`).
2. **`.data/build-snapshots/`** — automatic copies of `build/` before `make build`; manual `.env` copies (e.g. `.env.before-*`, `pre-env-refactor-*`):

   ```bash
   ls -lt .data/build-snapshots/*/.env .data/build-snapshots/pre-env-refactor-*/.env 2>/dev/null
   ```

3. **Tmp / old clone** — e.g. `~/tmp/vpnGit/amnezia-reality-kit/.data/.env` (verify with pubkey check below).
4. **`make create-data COPY_FROM=/path/to/.data/.env`** — only after you have a **verified** `.env`; never blind `make create-data` on prod (can generate **new** keys).

### After restoring `.data/.env`

```bash
cd <REPO_ROOT>

# Repo skeleton missing?
git restore --source=HEAD --worktree .

# Reload containers (required after server key change)
make refresh-full

# Mandatory pubkey check
echo "runtime: $(docker exec vpn-amneziawg awg show awg0 public-key)"
echo "client:  $(grep '^PublicKey' .data/clients_awg/evg.conf | awk '{print $3}')"
```

If `runtime` ≠ `client`, clients will not handshake — do **not** skip [Find matching private key](#find-matching-private-key-for-existing-clients).

### If backups are gone and clients still have old `.conf`

1. Read target from any client export:

   ```bash
   TARGET=$(grep '^PublicKey' .data/clients_awg/evg.conf | awk '{print $3}')
   echo "$TARGET"
   ```

2. Run the search script below over every `.env` candidate until `MATCH`.

3. Apply successful fix sequence above.

If **no** candidate matches: server key is lost. Options: (a) issue new client configs with `make awg-client-add` after a **new** server key (invalidates old `.conf`), or (b) restore from an external backup you may not have indexed in `.data/build-snapshots/`.

---

## Find matching private key for existing clients

```bash
cd <REPO_ROOT>

TARGET=$(grep '^PublicKey' .data/clients_awg/*.conf | head -1 | awk '{print $3}')
IMAGE="amneziawg:${AMNEZIAWG_RELEASE:-v3.1.20260812}"

for f in .data/.env .data/build-snapshots/*/.env .data/build-snapshots/pre-env-refactor-*/.env; do
  [[ -f "$f" ]] || continue
  priv=$(grep '^AWG_SERVER_PRIVATE_KEY=' "$f" | cut -d= -f2-)
  [[ -n "$priv" ]] || continue
  pub=$(printf '%s\n' "$priv" | docker run --rm -i --entrypoint awg "$IMAGE" pubkey 2>/dev/null) || continue
  if [[ "$pub" == "$TARGET" ]]; then
    echo "MATCH: $f"
    echo "  AWG_SERVER_PRIVATE_KEY=$priv"
    echo "  AWG_SERVER_PUBLIC_KEY=$pub"
  fi
done
```

**Note:** MATCH output contains secrets — copy into `.env` on the host only; do not paste into docs, tickets, or chat logs.

Safe `.env` update (avoids `sed` / base64 issues):

```bash
python3 <<'PY'
from pathlib import Path
priv = "PASTE_PRIVATE_FROM_MATCH"
pub  = "PASTE_PUBLIC_FROM_MATCH"
env = Path(".data/.env")
lines = []
for line in env.read_text().splitlines():
    if line.startswith("AWG_SERVER_PRIVATE_KEY="):
        lines.append(f"AWG_SERVER_PRIVATE_KEY={priv}")
    elif line.startswith("AWG_SERVER_PUBLIC_KEY="):
        lines.append(f"AWG_SERVER_PUBLIC_KEY={pub}")
    else:
        lines.append(line)
env.write_text("\n".join(lines) + "\n")
PY
```

---

## Rules (operator)

| Rule | Why |
|------|-----|
| **`make check` ≠ AWG key audit** | Phase 8 checks `.env` presence; Phase 9 checks container health — not client/server pubkey equality |
| **`.env` is the only AWG key store** | Do not maintain a parallel `keys/` mirror — it drifted from `.env` in production |
| **Always verify runtime vs client pubkey** | After any `.env` / build / recreate / restore |
| **Server key change ⇒ `make refresh-full`** | Bind-mounted `awg0.conf` + new `PrivateKey` needs full stack reload |
| **Avoid `make create-data` on prod without intent** | Always generates a fresh AWG keypair — breaks existing client `.conf` files |
| **Backup before key edits** | `cp -a .data/.env .data/build-snapshots/.env.before-$(date +%Y%m%d-%H%M%S)` |

→ [All documentation](./README.md)
