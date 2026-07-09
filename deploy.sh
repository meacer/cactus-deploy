#!/usr/bin/env bash
# Build cactus on Mac, push binary + configs to GCP VM, restart services.
# For first-time VM setup (installs packages), use --setup.
# By default, downloads CA and witness keys from GCP Secret Manager.
# To use local keys in keys/, use --local-keys.
# Usage:
#   ./deploy.sh                # deploy cactus binary + config (keys from Secret Manager)
#   ./deploy.sh --setup        # first deploy on a fresh VM
#   ./deploy.sh --local-keys   # deploy using local keys from keys/ directory
set -euo pipefail

VM="${CACTUS_VM:-https-testing}"
ZONE="${CACTUS_ZONE:-us-central1-a}"
PROJECT="${CACTUS_PROJECT:?Set CACTUS_PROJECT (e.g. export CACTUS_PROJECT=myproject)}"
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGING="/tmp/cactus-deploy"

SETUP=false
LOCAL_KEYS=false

for arg in "$@"; do
    case "$arg" in
        --setup)
            SETUP=true
            ;;
        --local|--local-keys)
            LOCAL_KEYS=true
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [--setup] [--local-keys]" >&2
            exit 1
            ;;
    esac
done

if [[ "$SETUP" == "true" ]]; then
    echo "==> Running first-time VM setup (Apache, no SSL)..."
    gcloud compute scp \
        "$DEPLOY_DIR/setup-vm.sh" \
        "$DEPLOY_DIR/apache-http.conf" \
        "$VM:/tmp/" \
        --zone="$ZONE" --project="$PROJECT"
    gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- \
        sudo bash /tmp/setup-vm.sh
fi

if [[ "$LOCAL_KEYS" == "true" ]]; then
    echo "==> Using local keys from $DEPLOY_DIR/keys..."
    KEYS_DIR="$DEPLOY_DIR/keys"
else
    echo "==> Downloading keys from GCP Secret Manager..."
    TMP_KEYS="$(mktemp -d)"
    trap '[[ -n "${TMP_KEYS:-}" ]] && rm -rf "$TMP_KEYS"' EXIT
    gcloud secrets versions access latest --secret=ca1-cosigner-seed --project="$PROJECT" > "$TMP_KEYS/ca-cosigner.seed"
    gcloud secrets versions access latest --secret=ca1-public-key --project="$PROJECT" > "$TMP_KEYS/ca-cosigner.pem"
    gcloud secrets versions access latest --secret=mirror1-cosigner-seed --project="$PROJECT" > "$TMP_KEYS/witness-cosigner.seed"
    gcloud secrets versions access latest --secret=mirror1-public-key --project="$PROJECT" > "$TMP_KEYS/witness-cosigner.pem"
    chmod 600 "$TMP_KEYS/"*.seed
    KEYS_DIR="$TMP_KEYS"
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
    "$KEYS_DIR/"*.pem \
    "$KEYS_DIR/"*.seed \
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
