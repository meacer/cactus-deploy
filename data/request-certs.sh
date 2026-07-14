#!/usr/bin/env bash
# Requests a certificate every 10 minutes using lego.
# Increments subdomain-N on each run.
set -euo pipefail

COUNTER_FILE="${COUNTER_FILE:-./.cert_counter}"
CERTS_DIR="${CERTS_DIR:-./certs}"

mkdir -p "$CERTS_DIR"

N=1
if [[ -f "$COUNTER_FILE" ]]; then
    N=$(cat "$COUNTER_FILE")
fi

while true; do
    echo "==> Requesting cert for subdomain-${N}.example.test..."
    lego --server http://localhost:14000/directory \
         --email you@example.com \
         --domains "subdomain-${N}.example.test" \
         --accept-tos \
         --http \
         --pem \
         --path "$CERTS_DIR" \
         run || echo "Warning: cert request for subdomain-${N}.example.test failed"

    N=$((N + 1))
    echo "$N" > "$COUNTER_FILE"

    echo "==> Waiting 1 minute for next request..."
    sleep 60
done
