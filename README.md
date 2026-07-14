# cactus-deploy

Deploy scripts for the cactus MTC CA server on a GCP VM.

All commands run on your **local machine** unless noted otherwise. `make setup`
and `make deploy` SSH into the VM automatically — you don't run anything on the
VM directly.

## Prerequisites (local, one-time)

VM name, zone, and GCP project default to the values in `config.sh` (sourced
by `deploy.sh`). Override any of them via `make` command-line variables:

```sh
make deploy                                                          # uses deploy.sh's defaults
make deploy CACTUS_PROJECT=myproject CACTUS_VM=my-vm CACTUS_ZONE=us-east1-b   # override
```

Calling `./deploy.sh` directly instead of via `make` works the same way,
with `--project=`, `--vm=`, `--zone=` flags overriding the built-in defaults
(see the usage comment at the top of `deploy.sh`).

```sh
export CACTUS_SRC=~/src/cactus     # Optional: path to existing cactus repo (default: auto-clones meacer/cactus)
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
# Create the VM (GCP) — substitute your own project/vm/zone if not using deploy.sh's defaults:
gcloud compute instances create cactus-testing-1 \
    --zone=us-central1-a --project=meacer \
    --machine-type=e2-micro \
    --image-family=debian-12 --image-project=debian-cloud

# Deploy (local, downloads keys from GCP Secret Manager by default):
make setup

# To deploy using local keys instead:
./deploy.sh --setup --local-keys
```

## Subsequent deploys (local)

```sh
make deploy
./deploy.sh --local-keys   # using local keys in keys/ directory
```

## Other commands (local)

```sh
make                              # build the Linux binary without deploying
make CACTUS_SRC=~/src/cactus      # build using an existing local cactus repo
make clean                        # remove cloned source (.cactus-src) and built binary
```

## Open firewall ports (GCP, one-time)

Required to access cactus directly via `http://<external-ip>:14080`. Substitute
your own project/vm/zone if not using deploy.sh's defaults:

```sh
# First time:
gcloud compute firewall-rules create allow-cactus \
    --project=meacer \
    --allow=tcp:14080,tcp:14081 \
    --target-tags=cactus \
    --source-ranges=0.0.0.0/0

gcloud compute instances add-tags cactus-testing-1 \
    --zone=us-central1-a --project=meacer \
    --tags=cactus

# To update an existing rule:
gcloud compute firewall-rules update allow-cactus \
    --project=meacer \
    --allow=tcp:14080,tcp:14081
```

Takes effect immediately — no VM restart needed.

## Delete the VM (GCP)

```sh
gcloud compute instances delete cactus-testing-1 --zone=us-central1-a --project=meacer
```

## Files

- `config.sh` — default VM/zone/project for deploy.sh
- `cactus-config.json` — cactus app config
- `cactus.service` — systemd unit
- `keys/` — cosigner seeds (secret, gitignored) and public keys
- `data/` — files copied to and run on the VM (Apache configs, `setup-vm.sh`)
