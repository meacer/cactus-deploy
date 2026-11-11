#!/usr/bin/env bash
# Downloads the CA and mirror cosigner seeds from GCP Secret Manager.
set -euo pipefail
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$DEPLOY_DIR/config.sh" ]]; then
  echo "Error: config.sh not found. Create it from the template:" >&2
  echo "  cp $DEPLOY_DIR/config.example.sh $DEPLOY_DIR/config.sh" >&2
  exit 1
fi
source "$DEPLOY_DIR/config.sh"
CA_SEED_SECRET="${CA_SEED_SECRET:-ca1-draft07-cosigner-seed}"
MIRROR_SEED_SECRET="${MIRROR_SEED_SECRET:-mirror1-draft07-cosigner-seed}"

KEYS_DIR="$HOME/src/cactus-keys-from-gcp"
mkdir -p "$KEYS_DIR"

echo "==> Downloading $CA_SEED_SECRET and $MIRROR_SEED_SECRET to $KEYS_DIR..."
gcloud secrets versions access latest --secret="$CA_SEED_SECRET"     --project="$PROJECT" --out-file="$KEYS_DIR/ca-cosigner.seed"
gcloud secrets versions access latest --secret="$MIRROR_SEED_SECRET" --project="$PROJECT" --out-file="$KEYS_DIR/mirror-cosigner.seed"
chmod 600 "$KEYS_DIR"/*

