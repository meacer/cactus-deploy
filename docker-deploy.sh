set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
CACTUS_DIR="${CACTUS_DIR:-$HOME/src/mcpherrinm-cactus}"
source "$DEPLOY_DIR/config.sh"

GO="${GO:-$HOME/go/bin/gotip}"
if ! command -v "$GO" >/dev/null 2>&1 && command -v go >/dev/null 2>&1; then
  GO=go
fi

OUT_DIR="$DEPLOY_DIR/out"
mkdir -p "$OUT_DIR"

echo "==> Building cactus-cli and requestmtc binaries to $OUT_DIR..."
(cd "$CACTUS_DIR" && GOOS=linux GOARCH=amd64 "$GO" build -o "$OUT_DIR/cactus-cli" ./cmd/cactus-cli)
GOOS=linux GOARCH=amd64 "$GO" build -o "$OUT_DIR/requestmtc" "$DEPLOY_DIR/data/requestmtc.go"

docker save cactus:local   | gzip | gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- "gunzip | docker load"

docker save sunlight:local | gzip | gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- "gunzip | docker load"

# Copy config files to the VM:
cd "$CACTUS_DIR"
gcloud compute scp --recurse ./docker "$VM":~/ --zone="$ZONE" --project="$PROJECT"

# Override with custom configs from cactus-deploy:
gcloud compute scp "$DEPLOY_DIR/data/apache-docker.conf" "$DEPLOY_DIR/data/compose.override.yaml" "$DEPLOY_DIR/data/skylight.yaml" "$VM":~/docker/ --zone="$ZONE" --project="$PROJECT"
gcloud compute scp "$DEPLOY_DIR/data/cactus-config-docker.json" "$VM":~/docker/cactus-config.json --zone="$ZONE" --project="$PROJECT"
gcloud compute scp "$DEPLOY_DIR/data/request-certs.sh" "$DEPLOY_DIR/data/requestmtc.go" "$DEPLOY_DIR/data/request-mtc-batch.sh" "$OUT_DIR/cactus-cli" "$OUT_DIR/requestmtc" "$VM":~/docker/ --zone="$ZONE" --project="$PROJECT"
gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- "chmod +x ~/docker/request-certs.sh ~/docker/request-mtc-batch.sh && sudo mkdir -p /var/lib/toolbox/bin && sudo cp ~/docker/cactus-cli ~/docker/requestmtc /var/lib/toolbox/bin/ && sudo chmod +x /var/lib/toolbox/bin/cactus-cli /var/lib/toolbox/bin/requestmtc"

# Populate secrets into Docker volumes and run compose up:
gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- bash << REMOTE
set -euo pipefail

# Ensure docker volumes exist:
docker volume create cactus_cactus-data >/dev/null
docker volume create cactus_sunlight-data >/dev/null

TMP_KEYS="\$(mktemp -d)"
trap 'rm -rf "\$TMP_KEYS"' EXIT

if gcloud secrets versions access latest --secret=ca1-cosigner-seed --project="$PROJECT" --out-file="\$TMP_KEYS/ca-cosigner.seed" 2>/dev/null; then
  echo "==> Populating ca-cosigner.seed into cactus_cactus-data volume..."
  docker run --rm -v cactus_cactus-data:/var/lib/cactus -v "\$TMP_KEYS":/keys:ro \
    alpine sh -c "mkdir -p /var/lib/cactus/keys && cp /keys/ca-cosigner.seed /var/lib/cactus/keys/ca-cosigner.seed"
fi

if gcloud secrets versions access latest --secret=mirror1-cosigner-seed --project="$PROJECT" --out-file="\$TMP_KEYS/witness-seed.bin" 2>/dev/null; then
  echo "==> Populating witness-seed.bin into cactus_sunlight-data volume..."
  docker run --rm -v cactus_sunlight-data:/var/lib/sunlight -v "\$TMP_KEYS":/keys:ro \
    alpine sh -c "mkdir -p /var/lib/sunlight && cp /keys/witness-seed.bin /var/lib/sunlight/witness-seed.bin"
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif docker-compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
elif [ -x /var/lib/toolbox/bin/docker-compose ]; then
  COMPOSE_CMD="/var/lib/toolbox/bin/docker-compose"
else
  echo "Installing docker-compose to /var/lib/toolbox/bin/docker-compose..."
  sudo mkdir -p /var/lib/toolbox/bin
  sudo curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 -o /var/lib/toolbox/bin/docker-compose
  sudo chmod +x /var/lib/toolbox/bin/docker-compose
  COMPOSE_CMD="/var/lib/toolbox/bin/docker-compose"
fi

if ! command -v lego >/dev/null 2>&1 && [ ! -x /var/lib/toolbox/bin/lego ]; then
  echo "Installing lego CLI to /var/lib/toolbox/bin/lego..."
  sudo mkdir -p /var/lib/toolbox/bin
  curl -sL https://github.com/go-acme/lego/releases/download/v4.16.1/lego_v4.16.1_linux_amd64.tar.gz | sudo tar xz -C /var/lib/toolbox/bin lego
  sudo chmod +x /var/lib/toolbox/bin/lego
fi

# Configure systemd timer to run MTC cert requests every Monday and Thursday
sudo tee /etc/systemd/system/request-mtc-cron.service >/dev/null << SERVICE
[Unit]
Description=Run MTC certificate requests for demo domains
After=network.target

[Service]
Type=oneshot
WorkingDirectory=/home/meacer/docker
ExecStart=/bin/bash /home/meacer/docker/request-mtc-batch.sh
SERVICE

sudo tee /etc/systemd/system/request-mtc-cron.timer >/dev/null << TIMER
[Unit]
Description=Run MTC certificate requests every Monday and Thursday

[Timer]
OnCalendar=Mon,Thu *-*-* 00:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now request-mtc-cron.timer

cd ~/docker
\$COMPOSE_CMD -f compose.yaml -f compose.override.yaml up -d
REMOTE
