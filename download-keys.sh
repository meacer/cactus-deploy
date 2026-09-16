set -euo pipefail
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
CACTUS_DIR="${CACTUS_DIR:-$HOME/src/meacer-cactus}"
source "$DEPLOY_DIR/config.sh" 

KEYS_DIR="~/src/cactus-keys-from-gcp"
mkdir -p "$KEYS_DIR"

echo "==> Downloading keys from Secret Manager to $KEYS_DIR..."
gcloud secrets versions access latest --secret=ca1-cosigner-seed     --project="$PROJECT" --out-file="$KEYS_DIR/ca-cosigner.seed"
gcloud secrets versions access latest --secret=mirror1-cosigner-seed --project="$PROJECT" --out-file="$KEYS_DIR/mirror-cosigner.seed"
chmod 600 "$KEYS_DIR"/*

