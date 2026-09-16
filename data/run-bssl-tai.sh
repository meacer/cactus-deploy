#!/usr/bin/env bash
# Wrapper script executed by bssl-tai.service to run bssl server instances for TAI demo domains:
#   - tai.demo.mtcs.dev on port 8443
#   - demo.mtcs.dev on port 8444
# Proxies decrypted HTTP traffic to Nginx on 127.0.0.1:9999.

set -euo pipefail

CERT_DIR="${CERT_DIR:-/home/meacer/docker/certs/certificates}"
BSSL_BIN="${BSSL_BIN:-/var/lib/toolbox/bin/bssl}"

sudo iptables -C INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
sudo iptables -C INPUT -p tcp --dport 8444 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -p tcp --dport 8444 -j ACCEPT

run_bssl_for_domain() {
    local domain="$1"
    local port="$2"
    local fallback_proxy="${3:-}"

    local key_file="${CERT_DIR}/${domain}.key"
    local lr_cert="${CERT_DIR}/${domain}-landmark-relative.pem"
    local fallback_cert="${CERT_DIR}/${domain}-standalone.crt"
    local taid_file="${CERT_DIR}/${domain}.taid"

    while [[ ! -f "$key_file" || ! -f "$lr_cert" || ! -f "$taid_file" ]]; do
        echo "==> [$(date -u)] Waiting for ${domain} certificates and Trust Anchor ID in ${CERT_DIR}..."
        sleep 10
    done

    local taid
    taid="$(tr -d '[:space:]' < "$taid_file")"
    local fallback_args=()
    if [[ -f "$fallback_cert" ]]; then
        fallback_args=(-tai-fallback-cert "$fallback_cert")
    fi

    local proxy_args=(-proxy 127.0.0.1:9999)
    if [[ -n "$fallback_proxy" ]]; then
        proxy_args+=(-tai-fallback-proxy "$fallback_proxy")
    fi

    echo "==> [$(date -u)] Starting bssl server for ${domain} on port ${port} (Trust Anchor ID: ${taid})"
    exec "$BSSL_BIN" server \
        -accept "$port" \
        -key "$key_file" \
        -cert "$lr_cert" \
        "${fallback_args[@]}" \
        -trust-anchor-id "$taid" \
        "${proxy_args[@]}" \
        -loop
}

trap 'kill $(jobs -p) 2>/dev/null || true' EXIT INT TERM

run_bssl_for_domain "tai.demo.mtcs.dev" 8443 &
run_bssl_for_domain "demo.mtcs.dev" 8444 "127.0.0.1:9998" &

wait -n
