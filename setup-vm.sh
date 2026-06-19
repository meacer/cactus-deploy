#!/usr/bin/env bash
# Idempotent first-time VM setup. Installs packages, sets up certbot,
# creates directories. Safe to run multiple times.
set -euo pipefail

DOMAINS=(
    ca1.test.mtcs.dev
    ca2.test.mtcs.dev
    mirror1.test.mtcs.dev
    mirror2.test.mtcs.dev
)

apt-get update
apt-get install -y apache2 certbot python3-certbot-apache

a2enmod proxy proxy_http ssl headers rewrite
mkdir -p /etc/cactus /var/lib/cactus

for domain in "${DOMAINS[@]}"; do
    if [ ! -d "/etc/letsencrypt/live/$domain" ]; then
        echo "==> Requesting cert for $domain..."
        certbot --apache -d "$domain" \
            --non-interactive --agree-tos --register-unsafely-without-email
    else
        echo "==> Cert already exists for $domain, skipping."
    fi
done

systemctl enable apache2
