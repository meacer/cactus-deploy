#!/usr/bin/env bash
# Wrapper script executed by bssl-tai.service to run bssl server instances for TAI demo domains:
#   - tai.demo.mtcs.dev on port 8443
#   - demo.mtcs.dev on port 8444
# Proxies decrypted HTTP traffic to Nginx on 127.0.0.1:9999.
#
# Certificate selection:
#   - Serve the landmark-relative MTC when one is available for the current key,
#     advertising the covering landmark's ID as the trust anchor ID (MTC §8.2).
#   - Otherwise serve the standalone MTC, advertising the CA ID (MTC §8.1).
#   - Clients that advertise no matching trust anchor get -tai-fallback-cert
#     (the publicly trusted WebPKI cert when one is available).
#
# Certificates are always paired with the key they were issued for: requestmtc
# installs a fresh key as soon as a new cert is issued, and the landmark-relative
# form only appears once a covering landmark exists, so the cert files on disk are
# briefly out of sync with each other. Picking a cert that does not match the key
# makes BoringSSL drop the private key and the server exit at startup, so each
# candidate is checked against the key before it is used.

set -euo pipefail

CERT_DIR="${CERT_DIR:-/home/meacer/docker/certs/certificates}"
BSSL_BIN="${BSSL_BIN:-/var/lib/toolbox/bin/bssl}"
CACTUS_CLI="${CACTUS_CLI:-/var/lib/toolbox/bin/cactus-cli}"

sudo iptables -C INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
sudo iptables -C INPUT -p tcp --dport 8444 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -p tcp --dport 8444 -j ACCEPT

# cert_matches_key succeeds when the certificate's public key is the one that
# belongs to the given private key.
cert_matches_key() {
    local cert="$1"
    local key="$2"
    [[ -f "$cert" && -f "$key" ]] || return 1

    local cert_pub key_pub
    cert_pub="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null)" || return 1
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null)" || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

# describe_cert prints "<trust anchor id>|<form>" for an MTC certificate: the
# landmark ID for a landmark-relative cert (MTC §8.2), or the issuing CA's ID for
# a standalone cert (MTC §8.1), which `cactus-cli cert text` reports as the issuer
# instead of a trust anchor ID.
describe_cert() {
    local cert="$1"
    local text taid form
    text="$("$CACTUS_CLI" cert text "$cert" 2>/dev/null)" || return 1

    form="$(sed -n 's/^[[:space:]]*form:[[:space:]]*//p' <<<"$text" | head -n 1)"
    taid="$(sed -n 's/^[[:space:]]*trust anchor id:[[:space:]]*//p' <<<"$text" | head -n 1)"
    if [[ -z "$taid" ]]; then
        taid="$(sed -n 's/^[[:space:]]*issuer:[[:space:]]*trustAnchorID=//p' <<<"$text" | head -n 1)"
    fi
    [[ -n "$taid" ]] || return 1

    printf '%s|%s\n' "$taid" "${form:-unknown}"
}

# select_cert prints "<cert path>|<trust anchor id>|<form>" for the best usable
# certificate for a domain: the landmark-relative form when it is available for
# the current key, otherwise the standalone form. <domain>.crt is the cert
# requestmtc keeps current (landmark-relative once one exists, standalone until
# then), so it is tried before the explicit standalone copy.
select_cert() {
    local domain="$1"
    local key="$2"
    local cert description
    for cert in "${CERT_DIR}/${domain}-landmark-relative.pem" \
                "${CERT_DIR}/${domain}.crt" \
                "${CERT_DIR}/${domain}-standalone.crt"; do
        if cert_matches_key "$cert" "$key" && description="$(describe_cert "$cert")"; then
            printf '%s|%s\n' "$cert" "$description"
            return 0
        fi
    done
    return 1
}

run_bssl_for_domain() {
    local domain="$1"
    local port="$2"
    local fallback_proxy="${3:-}"

    local key_file="${CERT_DIR}/${domain}.key"

    local selection=""
    while ! selection="$(select_cert "$domain" "$key_file")"; do
        echo "==> [$(date -u)] Waiting for a ${domain} certificate matching ${key_file} in ${CERT_DIR}..."
        sleep 10
    done

    local cert_file="${selection%%|*}"
    local rest="${selection#*|}"
    local taid="${rest%%|*}"
    local form="${rest#*|}"

    local le_cert="/home/meacer/docker/letsencrypt/live/${domain}/fullchain.pem"
    local le_key="/home/meacer/docker/letsencrypt/live/${domain}/privkey.pem"
    local fallback_cert="${CERT_DIR}/${domain}-standalone.crt"
    local fallback_args=()
    if [[ -f "$le_cert" && -f "$le_key" ]]; then
        fallback_args=(-tai-fallback-cert "$le_cert" -tai-fallback-key "$le_key")
    elif cert_matches_key "$fallback_cert" "$key_file"; then
        fallback_args=(-tai-fallback-cert "$fallback_cert")
    fi

    local proxy_args=(-proxy 127.0.0.1:9999)
    if [[ -n "$fallback_proxy" ]]; then
        proxy_args+=(-tai-fallback-proxy "$fallback_proxy")
    fi

    echo "==> [$(date -u)] Starting bssl server for ${domain} on port ${port} (${form} cert $(basename "$cert_file"), Trust Anchor ID: ${taid})"
    exec "$BSSL_BIN" server \
        -accept "$port" \
        -key "$key_file" \
        -cert "$cert_file" \
        "${fallback_args[@]}" \
        -trust-anchor-id "$taid" \
        "${proxy_args[@]}" \
        -loop
}

trap 'kill $(jobs -p) 2>/dev/null || true' EXIT INT TERM

run_bssl_for_domain "tai.demo.mtcs.dev" 8443 &
run_bssl_for_domain "demo.mtcs.dev" 8444 "127.0.0.1:9998" &

wait -n
