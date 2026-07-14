#!/usr/bin/env bash
# Wipes all cactus state on this VM: stops the service, deletes the data
# directory, and deletes the certs folder.
# Destructive and irreversible — asks for confirmation before doing anything.
set -euo pipefail

DATA_DIR="/var/lib/cactus"
CERTS_DIR="$HOME/certs"

echo "WARNING: this will irreversibly delete all cactus state on this VM (but not the keys):"
echo "  - stop the cactus service"
echo "  - delete $DATA_DIR (the log, tiles, and checkpoints)"
echo "  - delete $CERTS_DIR"
echo ""
read -r -p "Type 'yes' to continue: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

echo "==> Stopping cactus service..."
sudo systemctl stop cactus

echo "==> Deleting $DATA_DIR..."
sudo rm -rf "$DATA_DIR"

echo "==> Deleting $CERTS_DIR..."
sudo rm -rf "$CERTS_DIR"

echo "==> Done."
