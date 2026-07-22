#!/usr/bin/env bash
# Periodically requests MTC certificates every 5 days for:
#   - standalone.demo.mtcs.dev
#   - relative.demo.mtcs.dev (-relative)
#   - landmark-relative.demo.mtcs.dev (-relative)

set -euo pipefail

export PATH="/var/lib/toolbox/bin:$PATH"
REQUESTMTC_CMD="${REQUESTMTC_CMD:-/var/lib/toolbox/bin/requestmtc}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-432000}" # 5 days (5 * 86400)

run_requestmtc() {
    local domain="$1"
    shift
    echo "==> [$(date -u)] Requesting MTC cert for ${domain} $*..."
    "$REQUESTMTC_CMD" -domain "$domain" "$@" || echo "==> warning: failed to request cert for ${domain}"
}

while true; do
    run_requestmtc "standalone.demo.mtcs.dev"
    run_requestmtc "relative.demo.mtcs.dev" -relative
    run_requestmtc "landmark-relative.demo.mtcs.dev" -relative

    echo "==> [$(date -u)] Completed batch. Sleeping for 5 days (${INTERVAL_SECONDS}s)..."
    sleep "$INTERVAL_SECONDS"
done
