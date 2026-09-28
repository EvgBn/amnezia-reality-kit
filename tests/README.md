# Tests

```bash
make test                 # unit + integration + go (full suite)
make unit-test-shell      # tests/unit + tests/guards (fast, no Docker)
make unit-test-integration
make test-go              # udp-relay Go packages
make test-one TEST=mtproxy_sni
make unit-test-shell TEST_MATCH='test_mtproxy_*'
```

## Layout

| Directory | What runs here |
|-----------|----------------|
| **`unit/`** | Pure lib tests: source `scripts/lib/*`, mocks, temp dirs, &lt;~1s each |
| **`integration/`** | Full pipelines: `render-config.sh`, multi-lib host-remove flows |
| **`guards/`** | Repo invariants: no legacy paths, inventory sync, banned refs |
| **`lib/`** | `assert.sh`, `sandbox.sh`, `run-tests.sh`, `preflight.sh`, `fixture-env.sh` |
| **`fixtures/`** | Shared mocks — see [fixtures/README.md](fixtures/README.md) |

## Writing a unit test

```bash
#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../lib/sandbox.sh
source "$(cd "$(dirname "$0")/../lib" && pwd)/sandbox.sh"
# shellcheck source=../lib/assert.sh
source "$(cd "$(dirname "$0")/../lib" && pwd)/assert.sh"

test_repo_root
test_mktemp_sandbox TMP

# shellcheck source=../../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

eq "$(parse_bool "1" 0)" "1" "parse_bool true"

echo "OK: test_example"
```

## CI

`.github/workflows/ci.yml` runs `make unit-test-shell`, `make unit-test-integration`, and `make test-go` on push/PR.
