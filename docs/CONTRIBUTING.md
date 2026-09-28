# Contributing

← [Documentation](./README.md)

---

## Tests

```bash
make unit-test-shell      # fast: tests/unit + tests/guards
make unit-test            # + integration + go
make test-one TEST=verify_inbound
```

CI runs shellcheck on scripts and `tests/fixtures/**/*.sh`.

---

## Guards (invariants)

| Guard | Checks |
|-------|--------|
| `test_env_example_sync.sh` | `config/examples/.env.example` ≡ root `.env.example` |
| `test_template_envsubst_vars.sh` | Template `${VAR}` collection |
| `test_docs_user_quickstart.sh` | `docs/QUICKSTART.md` exists, ≤120 lines |

---

## Code change → docs

1. Find the topic in [docs/README.md](./README.md) and update that doc only — guides link, do not duplicate procedures.
2. If new env key → `config/examples/.env.example` + sync root `.env.example`.
3. If new template `${VAR}` → exported in `render-config.sh` or defaults; guard catches drift.
4. Bump **Last updated** on the canonical doc.

Operator-facing summary belongs in [QUICKSTART.md](./QUICKSTART.md) only when it changes the happy path (one line + link).

---

## Fixtures

See [tests/fixtures/README.md](../tests/fixtures/README.md). Prefer `fixture_load_case` over inline heredocs in new tests.

→ [All documentation](./README.md)
