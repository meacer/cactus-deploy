set -euo pipefail
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
CACTUS_DIR="${CACTUS_DIR:-$HOME/src/mcpherrinm-cactus}"
source "$DEPLOY_DIR/config.sh" 

KEYS_DIR="/tmp/cactus-keys-from-gcp"
mkdir -p "$KEYS_DIR"

echo "==> Downloading keys from Secret Manager..."
gcloud secrets versions access latest --secret=ca1-cosigner-seed     --project="$PROJECT" --out-file="$KEYS_DIR/ca-cosigner.seed"
gcloud secrets versions access latest --secret=mirror1-cosigner-seed --project="$PROJECT" --out-file="$KEYS_DIR/witness-seed.bin"
chmod 600 "$KEYS_DIR"/*

