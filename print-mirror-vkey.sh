#!/usr/bin/env bash
# Prints the live Sunlight mirror public key in SPKI PEM format with its SPKI SHA-256 hash,
# formatted for inclusion in signer_keys.pem and signer_set.textproto.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$DEPLOY_DIR/config.sh" ]]; then
  echo "Error: config.sh not found. Create it from the template:" >&2
  echo "  cp $DEPLOY_DIR/config.example.sh $DEPLOY_DIR/config.sh" >&2
  exit 1
fi
source "$DEPLOY_DIR/config.sh"

echo "==> Fetching Sunlight mirror public key from ${VM} (${ZONE})..." >&2
RAW_PEM=$(gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- '
docker run --rm -v cactus_cactus-data:/var/lib/cactus alpine sh -c "
  if [ ! -f /var/lib/cactus/keys/sunlight-mirror.pem ]; then
    echo \"Error: /var/lib/cactus/keys/sunlight-mirror.pem not found in volume cactus_cactus-data.\" >&2
    exit 1
  fi
  cat /var/lib/cactus/keys/sunlight-mirror.pem
"
')

# Convert the RAW ML-DSA-44 public key to SPKI format (adding the 22-byte SPKI DER prefix
# required by google3/mldsaencoding.ParseMLDSAPublicKey) and print with SPKI SHA-256 hash.
python3 -c '
import base64, hashlib, sys

spki_prefix = bytes([
    0x30, 0x82, 0x05, 0x32, 0x30, 0x0b, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x03, 0x11, 0x03, 0x82, 0x05, 0x21, 0x00
])

raw_pem = sys.stdin.read()
lines = [l.strip() for l in raw_pem.splitlines() if l.strip() and not l.startswith("-----")]
raw_bytes = base64.b64decode("".join(lines))
spki_bytes = spki_prefix + raw_bytes

sha = hashlib.sha256(spki_bytes).hexdigest()
spki_b64 = base64.b64encode(spki_bytes).decode("ascii")
b64_lines = [spki_b64[i:i+64] for i in range(0, len(spki_b64), 64)]

print(f"# {sha} - mtcs.dev Test Mirror1")
print("-----BEGIN PUBLIC KEY-----")
for line in b64_lines:
    print(line)
print("-----END PUBLIC KEY-----")
' <<< "$RAW_PEM"
