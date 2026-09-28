#!/usr/bin/env bash
# Route apply mock — success by default.
# contract: exit ROUTE_MOCK_RC (default 0)
# consumers: test_ensure_boot_exit
exit "${ROUTE_MOCK_RC:-0}"
