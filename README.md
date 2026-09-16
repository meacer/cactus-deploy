# cactus-deploy

Deploy scripts for the containerized cactus MTC CA stack (`cactus`, `sunlight`, `skylight`, `nginx`, `certbot`) on a GCP VM.

All commands run on your **local machine** unless noted otherwise. `make setup`
and `make deploy` (or `./docker-deploy.sh`) build the helper binaries locally, push
the locally-built Docker images and configs to the VM, and start the stack. The
`cactus:local` and `sunlight:local` images themselves are built separately, in
the cactus repo (see Prerequisites).

## Prerequisites (local, one-time)

VM name, zone, and GCP project default to the values in `config.sh` (sourced
by `docker-deploy.sh`). Override any of them via `make` command-line variables
or `./docker-deploy.sh` flags:

```sh
make deploy                                                          # uses config.sh defaults
make deploy CACTUS_PROJECT=myproject CACTUS_VM=my-vm CACTUS_ZONE=us-east1-b   # override
./docker-deploy.sh --vm=my-vm --zone=us-east1-b --project=myproject
```

`docker-deploy.sh` builds from two local checkouts:

| Variable | Default | Repository | Branch |
| --- | --- | --- | --- |
| `CACTUS_DIR` | `~/src/mcpherrinm-cactus` | [mcpherrinm/cactus](https://github.com/mcpherrinm/cactus) | `main` |
| `BORINGSSL_DIR` | `~/src/meacer-boringssl` | [meacer/boringssl](https://github.com/meacer/boringssl) | `tai-server` |

```sh
git clone https://github.com/mcpherrinm/cactus.git ~/src/mcpherrinm-cactus
```

`BORINGSSL_DIR` is only needed for the TAI demo site; `docker-deploy.sh` offers
to clone it for you.

This deployment patches three files from the cactus repo's `docker/` directory
(`skylight.yaml`, `init-sunlight.sh`, `sunlight.yaml.tmpl`). The patched copies
live in `data/` and are copied over the originals on the VM at deploy time, so
a clean checkout of `main` is all that is required — see the header comment in
each file for the delta.

This repo requires Go 1.27+. Until a release is available, use `gotip`:

```sh
go install golang.org/dl/gotip@latest
export PATH="$PATH:$HOME/go/bin"
gotip download
```

Build the `cactus:local` and `sunlight:local` Docker images. `docker-deploy.sh`
pushes these to the VM but does not build them, so this must be done at least
once, and again whenever the cactus source changes:

```sh
make -C ~/src/mcpherrinm-cactus docker-build
```

Generate CA + witness keys (only needed when creating new keys, e.g., after `./cactus-reset.sh`):

```sh
./cactus-reset.sh
```

## Fresh VM

```sh
# Create the VM (GCP) — substitute your own project/vm/zone if not using config.sh's defaults:
gcloud compute instances create cactus-testing \
    --zone=us-central1-a --project=meacer \
    --machine-type=e2-standard-2 \
    --image-family=cos-stable --image-project=cos-cloud

# First-time deploy (creates GCP firewall rules and deploys the Docker stack):
make setup
# or directly:
./docker-deploy.sh --setup-firewall
```

## Subsequent deploys (local)

```sh
make deploy
# or directly:
./docker-deploy.sh
```

## Trust Anchor Negotiation (TAI) demo site

To enable the TLS Trust Anchor Negotiation (`draft-ietf-tls-trust-anchor-ids`) demo site (`tai.demo.mtcs.dev`, served via `bssl server` with Nginx SNI routing on port 443 and standalone MTC fallback):

```sh
./docker-deploy.sh --enable-tai
# or via environment variable / config.sh:
ENABLE_TAI=true ./docker-deploy.sh
```

To disable it on a subsequent deploy:

```sh
./docker-deploy.sh --disable-tai
```

## Request an MTC certificate (on the VM)

`docker-deploy.sh` compiles `data/requestmtc.go` and installs the binary to `/var/lib/toolbox/bin/requestmtc` on the VM (and configures `request-mtc-cron.timer` to automatically renew demo certificates every Monday and Thursday).

To manually request a certificate for a domain from the local ACME server and serve it via Nginx over HTTPS, SSH into the VM and run:

```sh
gcloud compute ssh cactus-testing --zone=us-central1-a --project=meacer

cd ~/docker
/var/lib/toolbox/bin/requestmtc -domain example.test
/var/lib/toolbox/bin/requestmtc -domain example.test -email me@example.com
```

It writes each domain's Nginx vhost config to `~/docker/sites-enabled/<domain>.conf` and reloads the `cactus-nginx-1` container. Certificates land in `~/docker/certs/certificates`.

If `-relative` is passed, it converts the standalone cert into its landmark-relative form (draft §6.3.3) with `cactus-cli`, writing `certs/certificates/<domain>-landmark-relative.pem`, and uses that landmark-relative cert in the Nginx config. Optionally pass `-tai` to attach the TAI `CERTIFICATE PROPERTIES` block (`11129.11.99.1.1.1.<landmarkNumber>`):

```sh
/var/lib/toolbox/bin/requestmtc -domain example.test -relative
/var/lib/toolbox/bin/requestmtc -domain example.test -relative -tai
```

To do the landmark-relative conversion by hand:

```sh
/var/lib/toolbox/bin/cactus-cli cert landmark-relative ./certs/certificates/example.test.crt http://localhost:14080/1 > lr.pem
```

## Inspect the log with cactus-cli (on the VM)

`docker-deploy.sh` installs `cactus-cli` to `/var/lib/toolbox/bin/cactus-cli`. From the VM (or anywhere that can reach the log):

```sh
/var/lib/toolbox/bin/cactus-cli tree show   http://localhost:14080     # checkpoint: size + root
/var/lib/toolbox/bin/cactus-cli tree verify http://localhost:14080     # replay every tile, check the root
/var/lib/toolbox/bin/cactus-cli entry       http://localhost:14080 0   # decode a log entry
/var/lib/toolbox/bin/cactus-cli cert text   ./certs/certificates/example.test.crt   # human-readable view of a cert
/var/lib/toolbox/bin/cactus-cli cert verify ./certs/certificates/example.test.crt http://localhost:14080

# Convert a standalone cert to its landmark-relative form (prints PEM on stdout).
# Note the log number suffix (/1) — this endpoint is per-log, unlike those above:
/var/lib/toolbox/bin/cactus-cli cert landmark-relative ./certs/certificates/example.test.crt http://localhost:14080/1
```

## Open firewall ports (GCP, one-time)

`./docker-deploy.sh --setup-firewall` (or `make setup`) creates these rules automatically,
scoped to the VM's service account. To create or update them manually:

```sh
VM_SA=$(gcloud compute instances describe cactus-testing \
    --zone=us-central1-a --project=meacer \
    --format="get(serviceAccounts[0].email)")

gcloud compute firewall-rules create allow-http-https \
    --project=meacer \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:22,tcp:80,tcp:443 \
    --source-ranges=0.0.0.0/0 \
    --target-service-accounts="$VM_SA"

# Ports published by the compose stack: 14000 (ACME), 14080 (monitoring /
# tiles), 14090 (metrics), 8080 (sunlight), 8081 (skylight):
gcloud compute firewall-rules create allow-cactus \
    --project=meacer \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:8080,tcp:8081,tcp:14000,tcp:14080,tcp:14090 \
    --source-ranges=0.0.0.0/0 \
    --target-service-accounts="$VM_SA"
```

## Wipe the log state (on the VM)

Destructive and irreversible — this deletes the log, tiles, and checkpoints,
along with the cosigner seeds stored in the volumes. The seeds are re-populated
from GCP Secret Manager on the next deploy, but everything else is gone.

```sh
cd ~/docker
/var/lib/toolbox/bin/docker-compose -f compose.yaml -f compose.override.yaml down
docker volume rm cactus_cactus-data cactus_sunlight-data
```

Then run `./docker-deploy.sh` locally to recreate the volumes and restart the stack.

## Other commands (local)

```sh
make clean    # remove locally built binaries and generated pages (out/)
```

## Delete the VM (GCP)

```sh
gcloud compute instances delete cactus-testing --zone=us-central1-a --project=meacer
```

## Files

- `docker-deploy.sh` — builds tools and deploys the containerized stack to the GCP VM
- `config.sh` — default VM/zone/project and TAI configuration for `docker-deploy.sh`
- `cactus-reset.sh` — generates fresh CA and witness cosigner keys locally
- `download-keys.sh` — downloads cosigner seeds from GCP Secret Manager
- `print-mirror-vkey.sh` — prints the live Sunlight mirror SPKI public key from the VM
- `keys/` — cosigner seeds (secret, gitignored) and public keys
- `data/` — Docker/Nginx configs (`cactus-config-docker.json`, `compose.override.yaml`, `nginx.conf`, `skylight.yaml`), helper scripts, and Go tools (`requestmtc.go`, `generatemirrorindex.go`)
