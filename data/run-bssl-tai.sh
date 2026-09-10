#!/usr/bin/env bash
# Wrapper script executed by bssl-tai.service to run bssl server for tai.demo.mtcs.dev.
# Waits for tai.demo.mtcs.dev certificates and Trust Anchor ID (.taid) to be generated,
# then runs bssl server on port 8443 proxying decrypted HTTP traffic to Nginx on 127.0.0.1:8080.

set -euo pipefail

CERT_DIR="${CERT_DIR:-/home/meacer/docker/certs/certificates}"
BSSL_BIN="${BSSL_BIN:-/var/lib/toolbox/bin/bssl}"
DOMAIN="tai.demo.mtcs.dev"

KEY_FILE="${CERT_DIR}/${DOMAIN}.key"
LR_CERT="${CERT_DIR}/${DOMAIN}-landmark-relative.pem"
FALLBACK_CERT="${CERT_DIR}/${DOMAIN}-standalone.crt"
TAID_FILE="${CERT_DIR}/${DOMAIN}.taid"

while [[ ! -f "$KEY_FILE" || ! -f "$LR_CERT" || ! -f "$TAID_FILE" ]]; do
    echo "==> [$(date -u)] Waiting for ${DOMAIN} certificates and Trust Anchor ID in ${CERT_DIR}..."
    sleep 10
done

TAID="$(tr -d '[:space:]' < "$TAID_FILE")"
FALLBACK_ARGS=()
if [[ -f "$FALLBACK_CERT" ]]; then
    FALLBACK_ARGS=(-tai-fallback-cert "$FALLBACK_CERT")
fi

echo "==> [$(date -u)] Starting bssl server for ${DOMAIN} on port 8443 (Trust Anchor ID: ${TAID})"
exec "$BSSL_BIN" server \
    -accept 8443 \
    -key "$KEY_FILE" \
    -cert "$LR_CERT" \
    "${FALLBACK_ARGS[@]}" \
    -trust-anchor-id "$TAID" \
    -proxy 127.0.0.1:9999 \
    -loop
