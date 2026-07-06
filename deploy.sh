#!/usr/bin/env bash
# Build cactus on Mac, push binary + configs to GCP VM, restart services.
# For first-time VM setup (installs packages), use --setup.
# Usage:
#   ./deploy.sh            # deploy cactus binary + config
#   ./deploy.sh --setup    # first deploy on a fresh VM (installs packages, Apache HTTP only)
set -euo pipefail

VM="${CACTUS_VM:-https-testing}"
ZONE="${CACTUS_ZONE:-us-central1-a}"
PROJECT="${CACTUS_PROJECT:?Set CACTUS_PROJECT (e.g. export CACTUS_PROJECT=myproject)}"
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGING="/tmp/cactus-deploy"

if [[ "${1:-}" == "--setup" ]]; then
    echo "==> Running first-time VM setup (Apache, no SSL)..."
    gcloud compute scp \
        "$DEPLOY_DIR/setup-vm.sh" \
        "$DEPLOY_DIR/apache-http.conf" \
        "$VM:/tmp/" \
        --zone="$ZONE" --project="$PROJECT"
    gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- \
        sudo bash /tmp/setup-vm.sh
fi

echo "==> Copying cactus files to VM..."
gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- \
    "rm -rf $STAGING && mkdir -p $STAGING/keys"
gcloud compute scp \
    "$DEPLOY_DIR/bin/cactus" \
    "$DEPLOY_DIR/cactus-config.json" \
    "$DEPLOY_DIR/cactus.service" \
    "$DEPLOY_DIR/apache-http.conf" \
    "$DEPLOY_DIR/index.html" \
    "$VM:$STAGING/" \
    --zone="$ZONE" --project="$PROJECT"
gcloud compute scp \
    "$DEPLOY_DIR/keys/"*.pem \
    "$DEPLOY_DIR/keys/"*.seed \
    "$VM:$STAGING/keys/" \
    --zone="$ZONE" --project="$PROJECT"

echo "==> Deploying cactus on VM..."
gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- bash << REMOTE
set -euo pipefail

sudo mv $STAGING/cactus /usr/local/bin/cactus
sudo chmod +x /usr/local/bin/cactus

sudo mkdir -p /etc/cactus
sudo cp $STAGING/cactus-config.json /etc/cactus/config.json
sudo cp $STAGING/cactus.service /etc/systemd/system/cactus.service
sudo cp $STAGING/apache-http.conf /etc/apache2/sites-available/cactus.conf
sudo apache2ctl configtest && sudo systemctl reload apache2

sudo cp $STAGING/index.html /var/www/html/index.html

sudo mkdir -p /var/lib/cactus/keys
sudo cp $STAGING/keys/*.pem $STAGING/keys/*.seed /var/lib/cactus/keys/
sudo chmod 600 /var/lib/cactus/keys/*.seed

rm -rf $STAGING

sudo systemctl daemon-reload
sudo systemctl enable cactus
sudo systemctl restart cactus
sudo systemctl status cactus --no-pager

echo "==> Deploy complete"
REMOTE
