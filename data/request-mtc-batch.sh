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
    "$REQUESTMTC_CMD" -domain "$domain" "$@" || echo "==> warning: failed to request cert for ${domain}"
}

run_requestmtc "standalone.demo.mtcs.dev"
run_requestmtc "relative.demo.mtcs.dev" -relative
run_requestmtc "landmark-relative.demo.mtcs.dev" -relative

echo "==> [$(date -u)] Completed MTC batch request."
