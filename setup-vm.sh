#!/usr/bin/env bash
# First-time VM setup: installs packages, configures Apache over HTTP only.
# Idempotent — safe to run multiple times.
# Expects /tmp/apache-http.conf to be present (deploy.sh --setup copies it).
# Run certbot and deploy apache.conf separately once DNS and firewall are ready.
set -euo pipefail

apt-get update
apt-get install -y apache2 certbot

a2enmod proxy proxy_http ssl headers rewrite
a2dissite 000-default >/dev/null 2>&1 || true

cp /tmp/apache-http.conf /etc/apache2/sites-available/cactus.conf
a2ensite cactus >/dev/null 2>&1 || true

mkdir -p /etc/cactus /var/lib/cactus

systemctl enable apache2
systemctl restart apache2

IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" -H "Metadata-Flavor: Google")
echo ""
echo "==> VM external IP: $IP"
echo "==> If HTTP/HTTPS traffic is not working, allow it in GCP firewall settings:"
echo "    https://console.cloud.google.com/networking/firewalls"
echo "    Add rules for tcp:80 and tcp:443 from 0.0.0.0/0"
