set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
CACTUS_DIR="${CACTUS_DIR:-$HOME/src/mcpherrinm-cactus}"
source "$DEPLOY_DIR/config.sh"

docker save cactus:local   | gzip | gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- "gunzip | docker load"

docker save sunlight:local | gzip | gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- "gunzip | docker load"

# Copy config files to the VM:
cd "$CACTUS_DIR"
gcloud compute scp --recurse ./docker "$VM":~/ --zone="$ZONE" --project="$PROJECT"

# Ensure docker-compose is available on the VM and run compose up:
gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- bash << 'REMOTE'
set -euo pipefail

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

cd ~/docker
$COMPOSE_CMD -f compose.yaml up -d
REMOTE
