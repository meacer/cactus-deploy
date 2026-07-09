# cactus-deploy

Deploy scripts for the cactus MTC CA server on a GCP VM.

All commands run on your **local machine** unless noted otherwise. `make setup`
and `make deploy` SSH into the VM automatically — you don't run anything on the
VM directly.

## Prerequisites (local, one-time)

```sh
export CACTUS_PROJECT=myproject    # GCP project ID — add to your shell profile
export CACTUS_VM=https-testing     # VM name (default: https-testing)
export CACTUS_ZONE=us-central1-a   # VM zone (default: us-central1-a)
```

This repo requires Go 1.27+. Until a release is available, use `gotip`:

```sh
go install golang.org/dl/gotip@latest
export PATH="$PATH:$HOME/go/bin"
gotip download
```

Generate CA + witness keys (only needed when creating new keys, e.g., after `./cactus-reset.sh`):

```sh
./cactus-reset.sh
```

## Fresh VM

```sh
# Create the VM (GCP):
gcloud compute instances create $CACTUS_VM \
    --zone=$CACTUS_ZONE --project=$CACTUS_PROJECT \
    --machine-type=e2-micro \
    --image-family=debian-12 --image-project=debian-cloud

# Deploy (local, downloads keys from GCP Secret Manager by default):
make setup

# To deploy using local keys instead:
./deploy.sh --setup --local-keys
```

## Subsequent deploys (local)

```sh
make deploy                # deploys using keys from GCP Secret Manager
./deploy.sh --local-keys   # deploys using local keys in keys/ directory
```

## Other commands (local)

```sh
make          # build the Linux binary without deploying
make clean    # remove cloned source and built binary
```

## Open firewall ports (GCP, one-time)

Required to access cactus directly via `http://<external-ip>:14080`:

```sh
# First time:
gcloud compute firewall-rules create allow-cactus \
    --project=$CACTUS_PROJECT \
    --allow=tcp:14080,tcp:14081 \
    --target-tags=cactus \
    --source-ranges=0.0.0.0/0

gcloud compute instances add-tags $CACTUS_VM \
    --zone=$CACTUS_ZONE --project=$CACTUS_PROJECT \
    --tags=cactus

# To update an existing rule:
gcloud compute firewall-rules update allow-cactus \
    --project=$CACTUS_PROJECT \
    --allow=tcp:14080,tcp:14081
```

Takes effect immediately — no VM restart needed.

## Delete the VM (GCP)

```sh
gcloud compute instances delete $CACTUS_VM --zone=$CACTUS_ZONE --project=$CACTUS_PROJECT
```

## Files

- `cactus-config.json` — cactus app config
- `apache.conf` — Apache vhost config (all domains)
- `cactus.service` — systemd unit
- `keys/` — cosigner seeds (secret, gitignored) and public keys
