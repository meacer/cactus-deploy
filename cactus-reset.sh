#!/usr/bin/env bash
# Generate fresh CA and witness cosigner keys. Run this to start a new
# CA identity (e.g. after nuking the VM). Overwrites existing keys.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_DIR="$DEPLOY_DIR/keys"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "==> Cloning cactus..."
git clone --depth 1 https://github.com/meacer/cactus.git "$TMPDIR/cactus"
KEYGEN="$TMPDIR/cactus/cmd/cactus-keygen"

mkdir -p "$KEYS_DIR"

echo "==> Generating seeds..."
gotip run "$KEYGEN" -f -o "$KEYS_DIR/ca-cosigner.seed"
gotip run "$KEYGEN" -f -o "$KEYS_DIR/witness-cosigner.seed"

echo "==> Deriving public keys..."
gotip run "$KEYGEN" -pub -o "$KEYS_DIR/ca-cosigner.seed" > "$KEYS_DIR/ca-cosigner.pem"
gotip run "$KEYGEN" -pub -o "$KEYS_DIR/witness-cosigner.seed" > "$KEYS_DIR/witness-cosigner.pem"

echo "==> Done. Keys in $KEYS_DIR:"
ls -l "$KEYS_DIR"
