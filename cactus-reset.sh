#!/usr/bin/env bash
# Generate fresh CA and witness cosigner keys. Run this to start a new
# CA identity (e.g. after nuking the VM). Overwrites existing keys.
set -euo pipefail

GO="${GO:-gotip}"
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_DIR="$DEPLOY_DIR/keys"
CACTUS_SRC="${CACTUS_SRC:-}"

if [[ -z "$CACTUS_SRC" ]]; then
    if [[ -d "$DEPLOY_DIR/.cactus-src" ]]; then
        echo "==> Using local cactus repo at $DEPLOY_DIR/.cactus-src..."
        CACTUS_SRC="$DEPLOY_DIR/.cactus-src"
    else
        TMPDIR="$(mktemp -d)"
        trap '[[ -n "${TMPDIR:-}" ]] && rm -rf "$TMPDIR"' EXIT
        echo "==> Cloning cactus..."
        git clone --depth 1 https://github.com/meacer/cactus.git "$TMPDIR/cactus"
        CACTUS_SRC="$TMPDIR/cactus"
    fi
else
    echo "==> Using existing cactus repo at $CACTUS_SRC..."
    if [[ ! -d "$CACTUS_SRC" ]]; then
        echo "Error: CACTUS_SRC directory ($CACTUS_SRC) does not exist." >&2
        exit 1
    fi
fi

mkdir -p "$KEYS_DIR"

cd "$CACTUS_SRC"

echo "==> Generating seeds..."
$GO run ./cmd/cactus-keygen -f -o "$KEYS_DIR/ca-cosigner.seed"
$GO run ./cmd/cactus-keygen -f -o "$KEYS_DIR/witness-cosigner.seed"

echo "==> Deriving public keys..."
$GO run ./cmd/cactus-keygen -pub -o "$KEYS_DIR/ca-cosigner.seed" > "$KEYS_DIR/ca-cosigner.pem"
$GO run ./cmd/cactus-keygen -pub -o "$KEYS_DIR/witness-cosigner.seed" > "$KEYS_DIR/witness-cosigner.pem"

echo "==> Done. Keys in $KEYS_DIR:"
ls -l "$KEYS_DIR"
