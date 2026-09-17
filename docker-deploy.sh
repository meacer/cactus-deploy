#!/usr/bin/env bash
# Build and deploy the containerized cactus MTC CA stack (cactus, sunlight,
# skylight, nginx, certbot) to a GCP VM.
# Usage:
#   ./docker-deploy.sh
#   ./docker-deploy.sh --enable-tai
#   ./docker-deploy.sh --setup-firewall
#   ./docker-deploy.sh --vm=my-vm --zone=us-east1-b --project=myproject
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
CACTUS_DIR="${CACTUS_DIR:-$HOME/src/mcpherrinm-cactus}"
if [[ ! -f "$DEPLOY_DIR/config.sh" ]]; then
  echo "Error: config.sh not found. Create it from the template:" >&2
  echo "  cp $DEPLOY_DIR/config.example.sh $DEPLOY_DIR/config.sh" >&2
  exit 1
fi
source "$DEPLOY_DIR/config.sh"

SETUP_FIREWALL="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable-tai)
      ENABLE_TAI="true"
      shift
      ;;
    --disable-tai)
      ENABLE_TAI="false"
      shift
      ;;
    --setup-firewall)
      SETUP_FIREWALL="true"
      shift
      ;;
    --vm=*)
      VM="${1#*=}"
      shift
      ;;
    --zone=*)
      ZONE="${1#*=}"
      shift
      ;;
    --project=*)
      PROJECT="${1#*=}"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$VM" || -z "$ZONE" || -z "$PROJECT" ]]; then
  echo "Error: VM, zone, and project must not be empty." >&2
  exit 1
fi

if [[ "$SETUP_FIREWALL" == "true" ]]; then
  VM_SA=$(gcloud compute instances describe "$VM" --project="$PROJECT" --zone="$ZONE" --format="get(serviceAccounts[0].email)")

  echo "Creating firewall rules to allow SSH, HTTP, and HTTPS traffic to the VM service account $VM_SA"
  gcloud compute firewall-rules create allow-http-https \
    --project="$PROJECT" \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:22,tcp:80,tcp:443 \
    --source-ranges=0.0.0.0/0 \
    --target-service-accounts="$VM_SA" || true

  # Ports published by the compose stack: 14000 (ACME), 14080 (monitoring /
  # tiles), 14090 (metrics) from cactus; 8080 (sunlight), 8081 (skylight).
  echo "Creating firewall rules to allow Cactus traffic to the VM service account $VM_SA"
  gcloud compute firewall-rules create allow-cactus \
    --project="$PROJECT" \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:8080,tcp:8081,tcp:14000,tcp:14080,tcp:14090 \
    --source-ranges=0.0.0.0/0 \
    --target-service-accounts="$VM_SA" || true
fi

GO="${GO:-$HOME/go/bin/gotip}"
if ! command -v "$GO" >/dev/null 2>&1 && command -v go >/dev/null 2>&1; then
  GO=go
fi

OUT_DIR="$DEPLOY_DIR/out"
mkdir -p "$OUT_DIR"

# Generate mirror index HTML page locally before deployment:
"$GO" run "$DEPLOY_DIR/data/generatemirrorindex.go" -config "$DEPLOY_DIR/data/cactus-config-docker.json" -key "$DEPLOY_DIR/keys/mirror-cosigner.pem" -out "$OUT_DIR/www/mirror1/index.html"

echo "==> Building cactus-cli and requestmtc binaries to $OUT_DIR..."
(cd "$CACTUS_DIR" && GOOS=linux GOARCH=amd64 "$GO" build -o "$OUT_DIR/cactus-cli" ./cmd/cactus-cli)
GOOS=linux GOARCH=amd64 "$GO" build -o "$OUT_DIR/requestmtc" "$DEPLOY_DIR/data/requestmtc.go"

if [ "${ENABLE_TAI:-false}" = "true" ] || [ ! -x "$OUT_DIR/bssl" ]; then
  if [ ! -d "${BORINGSSL_DIR:-}" ]; then
    read -r -p "BORINGSSL_DIR ($BORINGSSL_DIR) does not exist. Clone https://github.com/meacer/boringssl (branch tai-server) into $BORINGSSL_DIR? [y/N] " reply
    if [[ "$reply" =~ ^[Yy] ]]; then
      git clone -b tai-server https://github.com/meacer/boringssl "$BORINGSSL_DIR"
    fi
  fi
  if [ -d "${BORINGSSL_DIR:-}" ]; then
    echo "==> Building static bssl server binary from $BORINGSSL_DIR via Alpine Docker..."
    docker run --rm -v "$BORINGSSL_DIR:/src:ro" -v "$OUT_DIR:/out" alpine sh -c "
      apk add --no-cache cmake make g++ go perl linux-headers &&
      cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXE_LINKER_FLAGS='-static' &&
      cmake --build /build --target bssl -j\$(nproc) &&
      strip -o /out/bssl /build/bssl
    "
  elif [ "${ENABLE_TAI:-false}" = "true" ] && [ ! -x "$OUT_DIR/bssl" ]; then
    echo "Error: ENABLE_TAI=true but BORINGSSL_DIR ($BORINGSSL_DIR) does not exist and $OUT_DIR/bssl is missing" >&2
    exit 1
  fi
fi

# The cactus:local and sunlight:local images are built out-of-band from
# $CACTUS_DIR, not by this script. Fail early with a useful message rather than
# letting `docker save` report a bare "reference does not exist".
for image in cactus:local sunlight:local; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Error: Docker image $image not found locally. Build the images first:" >&2
    echo "  make -C $CACTUS_DIR docker-build" >&2
    exit 1
  fi
done

docker save cactus:local   | gzip | gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- "gunzip | docker load"

docker save sunlight:local | gzip | gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- "gunzip | docker load"

# Copy config files to the VM:
cd "$CACTUS_DIR"
gcloud compute scp --recurse ./docker "$VM":~/ --zone="$ZONE" --project="$PROJECT"

# Override with custom configs from cactus-deploy. init-sunlight.sh and
# sunlight.yaml.tmpl are patched copies of the cactus repo's versions; see the
# header comment in each for the delta.
gcloud compute scp \
  "$DEPLOY_DIR/data/nginx.conf" \
  "$DEPLOY_DIR/data/compose.override.yaml" \
  "$DEPLOY_DIR/data/skylight.yaml" \
  "$DEPLOY_DIR/data/init-sunlight.sh" \
  "$DEPLOY_DIR/data/sunlight.yaml.tmpl" \
  "$DEPLOY_DIR/data/run-bssl-tai.sh" \
  "$VM":~/docker/ --zone="$ZONE" --project="$PROJECT"
if [ -x "$OUT_DIR/bssl" ]; then
  gcloud compute scp "$OUT_DIR/bssl" "$VM":~/docker/ --zone="$ZONE" --project="$PROJECT"
fi
gcloud compute scp --recurse "$OUT_DIR/www" "$VM":~/docker/ --zone="$ZONE" --project="$PROJECT"
gcloud compute scp "$DEPLOY_DIR/data/cactus-config-docker.json" "$VM":~/docker/cactus-config.json --zone="$ZONE" --project="$PROJECT"
gcloud compute scp "$DEPLOY_DIR/data/request-certs.sh" "$DEPLOY_DIR/data/requestmtc.go" "$DEPLOY_DIR/data/request-demo-domain-certs.sh" "$DEPLOY_DIR/data/generate-demo-html.sh" "$OUT_DIR/cactus-cli" "$OUT_DIR/requestmtc" "$VM":~/docker/ --zone="$ZONE" --project="$PROJECT"
gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- "chmod +x ~/docker/request-certs.sh ~/docker/request-demo-domain-certs.sh ~/docker/generate-demo-html.sh ~/docker/run-bssl-tai.sh && sudo mkdir -p /var/lib/toolbox/bin && sudo install -m 0755 ~/docker/cactus-cli ~/docker/requestmtc /var/lib/toolbox/bin/ && if [ -x ~/docker/bssl ]; then sudo install -m 0755 ~/docker/bssl /var/lib/toolbox/bin/; fi"

LOCAL_TMP_KEYS="$(mktemp -d)"
trap 'rm -rf "$LOCAL_TMP_KEYS"' EXIT

echo "==> Fetching secrets from GCP Secret Manager locally..."
HAS_CA_SEED=false
HAS_MIRROR_SEED=false

if gcloud secrets versions access latest --secret=ca1-cosigner-seed --project="$PROJECT" --out-file="$LOCAL_TMP_KEYS/ca-cosigner.seed" 2>/dev/null; then
  echo "  Downloaded ca1-cosigner-seed"
  HAS_CA_SEED=true
else
  echo "  Warning: could not fetch ca1-cosigner-seed from Secret Manager"
fi

if gcloud secrets versions access latest --secret=mirror1-cosigner-seed --project="$PROJECT" --out-file="$LOCAL_TMP_KEYS/mirror-cosigner.seed" 2>/dev/null; then
  echo "  Downloaded mirror1-cosigner-seed"
  HAS_MIRROR_SEED=true
else
  echo "  Warning: could not fetch mirror1-cosigner-seed from Secret Manager"
fi

if [ "$HAS_CA_SEED" = true ] || [ "$HAS_MIRROR_SEED" = true ]; then
  gcloud compute scp --recurse "$LOCAL_TMP_KEYS" "$VM":/tmp/cactus-keys --zone="$ZONE" --project="$PROJECT"
fi

# Populate secrets into Docker volumes and run compose up:
gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" -- bash << REMOTE
set -euo pipefail

# Ensure docker volumes exist:
docker volume create cactus_cactus-data >/dev/null
docker volume create cactus_sunlight-data >/dev/null

if [ -f /tmp/cactus-keys/ca-cosigner.seed ]; then
  echo "==> Populating ca-cosigner.seed into cactus_cactus-data volume..."
  docker run --rm -v cactus_cactus-data:/var/lib/cactus -v /tmp/cactus-keys:/keys:ro \
    alpine sh -c "mkdir -p /var/lib/cactus/keys && cp /keys/ca-cosigner.seed /var/lib/cactus/keys/ca-cosigner.seed && chmod 600 /var/lib/cactus/keys/ca-cosigner.seed"
fi

# The in-volume name is fixed by upstream's sunlight.yaml.tmpl and
# init-sunlight.sh, so it stays witness-seed.bin regardless of what we call the
# seed locally.
if [ -f /tmp/cactus-keys/mirror-cosigner.seed ]; then
  echo "==> Populating mirror-cosigner.seed into cactus_sunlight-data volume as witness-seed.bin..."
  docker run --rm -v cactus_sunlight-data:/var/lib/sunlight -v /tmp/cactus-keys:/keys:ro \
    alpine sh -c "mkdir -p /var/lib/sunlight && cp /keys/mirror-cosigner.seed /var/lib/sunlight/witness-seed.bin && chmod 600 /var/lib/sunlight/witness-seed.bin"
fi

rm -rf /tmp/cactus-keys

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
ExecStart=/bin/bash /home/meacer/docker/request-demo-domain-certs.sh
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

# Configure systemd service for request-certs.sh loop
sudo tee /etc/systemd/system/request-certs.service >/dev/null << SERVICE
[Unit]
Description=Continuous certificate request loop
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/meacer/docker
ExecStart=/bin/bash /home/meacer/docker/request-certs.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable request-certs.service
if ! systemctl is-active --quiet request-certs.service; then
  echo "==> Starting request-certs.service..."
  sudo systemctl start request-certs.service
fi

# Configure systemd service for bssl TAI server
sudo tee /etc/systemd/system/bssl-tai.service >/dev/null << SERVICE
[Unit]
Description=BoringSSL TAI Server for tai.demo.mtcs.dev
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/meacer/docker
ExecStart=/bin/bash /home/meacer/docker/run-bssl-tai.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
if [ "${ENABLE_TAI}" = "true" ]; then
  echo "==> Allowing ports 8443 and 8444 in host iptables and enabling bssl-tai.service..."
  sudo iptables -C INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
  sudo iptables -C INPUT -p tcp --dport 8444 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -p tcp --dport 8444 -j ACCEPT
  sudo systemctl enable bssl-tai.service
  sudo systemctl restart bssl-tai.service
else
  sudo systemctl stop bssl-tai.service || true
  sudo systemctl disable bssl-tai.service || true
fi

mkdir -p ~/docker/sites-enabled
sudo chown -R \$(id -u):\$(id -g) ~/docker/sites-enabled ~/docker/www 2>/dev/null || true
# Remove any legacy Apache VirtualHost configs from sites-enabled
grep -l '<VirtualHost' ~/docker/sites-enabled/*.conf 2>/dev/null | xargs -r rm -f || true
echo "ENABLE_TAI=${ENABLE_TAI}" > ~/docker/enable-tai.env
if [ "${ENABLE_TAI}" = "true" ]; then
  cat > ~/docker/tai-stream-map.conf <<'EOF'
tai.demo.mtcs.dev tai_backend;
demo.mtcs.dev demo_tai_backend;
EOF
else
  : > ~/docker/tai-stream-map.conf
  rm -f ~/docker/sites-enabled/tai.demo.mtcs.dev.conf ~/docker/sites-enabled/demo.mtcs.dev.conf
fi

cd ~/docker
\$COMPOSE_CMD -f compose.yaml -f compose.override.yaml up -d --remove-orphans

CERTBOT_DOMAINS="ca1.test.mtcs.dev mirror1.test.mtcs.dev"
if [ "${ENABLE_TAI}" = "true" ]; then
  CERTBOT_DOMAINS="\$CERTBOT_DOMAINS demo.mtcs.dev"
fi
for domain in \$CERTBOT_DOMAINS; do
  if ! sudo test -f "./letsencrypt/live/\$domain/fullchain.pem"; then
    echo "==> Requesting Let's Encrypt certificate for \$domain..."
    \$COMPOSE_CMD -f compose.yaml -f compose.override.yaml exec -T certbot \
      certbot certonly --webroot -w /var/www/certbot -d "\$domain" \
      --non-interactive --agree-tos -m meacer@chromium.org < /dev/null
  fi
done

if sudo test -f "./letsencrypt/live/ca1.test.mtcs.dev/fullchain.pem"; then
  cat > ~/docker/sites-enabled/ca1.test.mtcs.dev.conf << 'EOF'
server {
    listen 4443 ssl;
    server_name ca1.test.mtcs.dev;
    ssl_certificate /etc/letsencrypt/live/ca1.test.mtcs.dev/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ca1.test.mtcs.dev/privkey.pem;
    location / {
        set \$cactus_upstream "cactus:14080";
        proxy_pass http://\$cactus_upstream;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
fi

if sudo test -f "./letsencrypt/live/mirror1.test.mtcs.dev/fullchain.pem"; then
  cat > ~/docker/sites-enabled/mirror1.test.mtcs.dev.conf << 'EOF'
server {
    listen 4443 ssl;
    server_name mirror1.test.mtcs.dev;
    ssl_certificate /etc/letsencrypt/live/mirror1.test.mtcs.dev/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mirror1.test.mtcs.dev/privkey.pem;
    root /var/www/mirror1;
    index index.html;
    location /mirror/ {
        set \$skylight_upstream "skylight:8081";
        proxy_pass http://\$skylight_upstream;
        proxy_set_header Host \$host;
    }
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
fi

# Ensure Nginx vhosts exist for any demo domain whose certificate is already present in ~/docker/certs/certificates
for domain in standalone.demo.mtcs.dev relative.demo.mtcs.dev landmark-relative.demo.mtcs.dev tai.demo.mtcs.dev; do
  if [ "\$domain" = "tai.demo.mtcs.dev" ] && [ "${ENABLE_TAI}" != "true" ]; then
    continue
  fi
  cert_file=""
  if [ -f "./certs/certificates/\${domain}-landmark-relative.pem" ]; then
    cert_file="\${domain}-landmark-relative.pem"
  elif [ -f "./certs/certificates/\${domain}.crt" ]; then
    cert_file="\${domain}.crt"
  fi
  if [ -n "\$cert_file" ] && [ -f "./certs/certificates/\${domain}.key" ]; then
    sudo tee ~/docker/sites-enabled/\${domain}.conf >/dev/null << EOF
server {
    listen 80;
    server_name \${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\\\$host\\\$request_uri;
    }
}

server {
    listen 4443 ssl;
    server_name \${domain};
    root /var/www/\${domain};
    index index.html;

    ssl_certificate /etc/certs/certificates/\${cert_file};
    ssl_certificate_key /etc/certs/certificates/\${domain}.key;
    ssl_ciphers DEFAULT:@SECLEVEL=0;
}
EOF
  fi
done

echo "==> Generating rich demo HTML pages from existing certificates..."
bash ~/docker/generate-demo-html.sh

echo "==> Restarting Nginx container to pick up SSL certificates..."
\$COMPOSE_CMD -f compose.yaml -f compose.override.yaml restart nginx
REMOTE
