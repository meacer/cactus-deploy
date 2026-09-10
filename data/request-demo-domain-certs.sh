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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/enable-tai.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/enable-tai.env"
fi

if [[ "${ENABLE_TAI:-false}" == "true" ]]; then
    run_requestmtc "relative.demo.mtcs.dev,landmark-relative.demo.mtcs.dev,tai.demo.mtcs.dev" -relative -tai
else
    run_requestmtc "relative.demo.mtcs.dev,landmark-relative.demo.mtcs.dev" -relative
fi

if [[ -f "${SCRIPT_DIR}/generate-demo-html.sh" ]]; then
    bash "${SCRIPT_DIR}/generate-demo-html.sh"
fi

echo "==> [$(date -u)] Completed MTC batch request."
