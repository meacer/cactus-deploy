#!/usr/bin/env bash
# Build cactus on Mac, push binary + configs to GCP VM, restart services.
# Usage:
#   ./deploy.sh            # deploy binary + configs
#   ./deploy.sh --setup    # first deploy on a fresh VM (installs packages, certbot, etc.)
set -euo pipefail

VM="${CACTUS_VM:-https-testing}"
ZONE="${CACTUS_ZONE:-us-central1-a}"
PROJECT="${CACTUS_PROJECT:?Set CACTUS_PROJECT (e.g. export CACTUS_PROJECT=myproject)}"
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Copying files to VM..."
gcloud compute scp \
    "$DEPLOY_DIR/bin/cactus" \
    "$DEPLOY_DIR/cactus-config.json" \
    "$DEPLOY_DIR/apache.conf" \
    "$DEPLOY_DIR/cactus.service" \
    "$VM:/tmp/" \
    --zone="$ZONE" --project="$PROJECT"
gcloud compute scp --recurse \
    "$DEPLOY_DIR/keys" \
    "$VM:/tmp/cactus-keys" \
    --zone="$ZONE" --project="$PROJECT"

if [[ "${1:-}" == "--setup" ]]; then
    echo "==> Running first-time VM setup..."
    gcloud compute scp "$DEPLOY_DIR/setup-vm.sh" "$VM:/tmp/setup-vm.sh" \
        --zone="$ZONE" --project="$PROJECT"
    gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- bash << 'SETUP'
set -euo pipefail
sudo cp /tmp/apache.conf /etc/apache2/sites-available/cactus.conf
sudo a2ensite cactus >/dev/null 2>&1 || true
sudo systemctl reload apache2
sudo bash /tmp/setup-vm.sh
SETUP
fi

echo "==> Deploying on VM..."
gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- bash << 'REMOTE'
set -euo pipefail

sudo mv /tmp/cactus /usr/local/bin/cactus
sudo chmod +x /usr/local/bin/cactus

sudo cp /tmp/cactus-config.json /etc/cactus/config.json
sudo cp /tmp/apache.conf /etc/apache2/sites-available/cactus.conf
sudo cp /tmp/cactus.service /etc/systemd/system/cactus.service

sudo mkdir -p /var/lib/cactus/keys
sudo cp /tmp/cactus-keys/* /var/lib/cactus/keys/
sudo chmod 600 /var/lib/cactus/keys/*.seed

sudo a2ensite cactus >/dev/null 2>&1 || true
sudo apache2ctl configtest
sudo systemctl daemon-reload
sudo systemctl reload apache2
sudo systemctl restart cactus
sudo systemctl status cactus --no-pager

echo "==> Deploy complete"
REMOTE
