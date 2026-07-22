#!/usr/bin/env bash
# Requests a certificate periodically using lego (via native binary or docker container).
# Increments subdomain-N on each run.
set -euo pipefail

COUNTER_FILE="${COUNTER_FILE:-./.cert_counter}"
CERTS_DIR="${CERTS_DIR:-$(pwd)/certs}"
SERVER_URL="${SERVER_URL:-http://localhost:14000/directory}"
EMAIL="${EMAIL:-meacer@chromium.org}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-10}"

mkdir -p "$CERTS_DIR"

N=1
if [[ -f "$COUNTER_FILE" ]]; then
    N=$(cat "$COUNTER_FILE")
fi

run_lego() {
    local domain="$1"
    if command -v lego >/dev/null 2>&1; then
        lego --server "$SERVER_URL" \
             --email "$EMAIL" \
             --domains "$domain" \
             --accept-tos \
             --http \
             --pem \
             --path "$CERTS_DIR" \
             run
    elif [ -x /var/lib/toolbox/bin/lego ]; then
        /var/lib/toolbox/bin/lego --server "$SERVER_URL" \
             --email "$EMAIL" \
             --domains "$domain" \
             --accept-tos \
             --http \
             --pem \
             --path "$CERTS_DIR" \
             run
    else
        docker run --rm --net=host \
            -v "$CERTS_DIR":/.lego \
            goacme/lego:v4.16.1 \
            --server "$SERVER_URL" \
            --email "$EMAIL" \
            --domains "$domain" \
            --accept-tos \
            --http \
            --pem \
            run
    fi
}

while true; do
    echo "==> Requesting cert for subdomain-${N}.example.test..."
    run_lego "subdomain-${N}.example.test" || echo "Warning: cert request for subdomain-${N}.example.test failed"

    N=$((N + 1))
    echo "$N" > "$COUNTER_FILE"

    echo ">>> Waiting ${INTERVAL_SECONDS} seconds for next request..."
    sleep "$INTERVAL_SECONDS"
done
