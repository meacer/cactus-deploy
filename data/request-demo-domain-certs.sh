#!/usr/bin/env bash
# Runs a single batch of MTC cert requests for:
#   - standalone.demo.mtcs.dev
#   - relative.demo.mtcs.dev (-relative)
#   - landmark-relative.demo.mtcs.dev (-relative)

set -euo pipefail

export PATH="/var/lib/toolbox/bin:$PATH"
REQUESTMTC_CMD="${REQUESTMTC_CMD:-/var/lib/toolbox/bin/requestmtc}"

run_requestmtc() {
    local domain="$1"
    shift
    echo "==> [$(date -u)] Requesting MTC cert for ${domain} $*..."
    if ! "$REQUESTMTC_CMD" -domain "$domain" "$@"; then
        echo "==> ERROR: failed to request cert for ${domain}" >&2
        exit 1
    fi
}

run_requestmtc "standalone.demo.mtcs.dev"
run_requestmtc "relative.demo.mtcs.dev,landmark-relative.demo.mtcs.dev" -relative

echo "==> [$(date -u)] Completed MTC batch request."
