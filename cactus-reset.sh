#!/usr/bin/env bash
# Generate fresh CA and mirror cosigner keys. Run this to start a new
# CA identity (e.g. after nuking the VM). Overwrites existing keys.
# Sunlight derives both its witness and mirror keys from the mirror seed.
set -euo pipefail

GO="${GO:-go}"
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_DIR="$DEPLOY_DIR/keys"
CACTUS_SRC="${CACTUS_SRC:-}"
CACTUS_DIR="${CACTUS_DIR:-$HOME/src/mcpherrinm-cactus}"

if [[ -z "$CACTUS_SRC" ]]; then
    if [[ -d "$CACTUS_DIR" ]]; then
        echo "==> Using local cactus repo at $CACTUS_DIR..."
        CACTUS_SRC="$CACTUS_DIR"
    else
        TMPDIR="$(mktemp -d)"
        trap '[[ -n "${TMPDIR:-}" ]] && rm -rf "$TMPDIR"' EXIT
        echo "==> Cloning cactus..."
        git clone --depth 1 https://github.com/mcpherrinm/cactus.git "$TMPDIR/cactus"
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

# cactus-keygen -f overwrites, so refuse to clobber an existing identity: its
# seeds may be the only local copy. Move them aside first (e.g. to
# keys-<name>/) or set FORCE=1.
if [[ "${FORCE:-0}" != 1 ]]; then
    for f in ca-cosigner.seed mirror-cosigner.seed; do
        if [[ -e "$KEYS_DIR/$f" ]]; then
            echo "Error: $KEYS_DIR/$f exists; move keys/ aside or set FORCE=1 to overwrite." >&2
            exit 1
        fi
    done
fi

cd "$CACTUS_SRC"

echo "==> Generating seeds..."
$GO run ./cmd/cactus-keygen -f -o "$KEYS_DIR/ca-cosigner.seed"
$GO run ./cmd/cactus-keygen -f -o "$KEYS_DIR/mirror-cosigner.seed"

echo "==> Deriving public keys..."
$GO run ./cmd/cactus-keygen -pub -o "$KEYS_DIR/ca-cosigner.seed" > "$KEYS_DIR/ca-cosigner.pem"
$GO run ./cmd/cactus-keygen -pub -o "$KEYS_DIR/mirror-cosigner.seed" > "$KEYS_DIR/mirror-cosigner.pem"

echo "==> Done. Keys in $KEYS_DIR:"
ls -l "$KEYS_DIR"
