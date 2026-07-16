# cactus-deploy

Deploy scripts for the cactus MTC CA server on a GCP VM.

All commands run on your **local machine** unless noted otherwise. `make setup`
and `make deploy` SSH into the VM automatically — the only step you run on the
VM directly is requesting an MTC certificate (see below).

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
make                              # build the Linux binaries without deploying (clones/builds main)
make CACTUS_BRANCH=my-branch      # build from a different branch of the auto-cloned repo
make CACTUS_SRC=~/src/cactus      # build using an existing local cactus repo (branch left as-is)
make clean                        # remove cloned source (.cactus-src) and built binaries
```

## Request an MTC certificate (on the VM)

`deploy.sh` copies `data/requestmtc.go` to `/usr/local/share/cactus/` on the VM,
and `setup-vm.sh` installs Go there. To request a certificate for a domain from
a local ACME server and serve it over HTTPS, SSH in and run it from source:

```sh
gcloud compute ssh cactus-testing-1 --zone=us-central1-a --project=meacer

go run /usr/local/share/cactus/requestmtc.go -domain example.test
go run /usr/local/share/cactus/requestmtc.go -domain example.test -email me@example.com
```

It writes each domain's Apache config to `/etc/apache2/sites-available/mtc-<domain>.conf`
via `sudo`, so run it as your normal SSH user rather than as root. Certificates
land in `./certs` relative to your working directory; override with `-path`.

Once the site is serving, it converts the standalone cert into its
landmark-relative form (draft §6.3.3) with `cactus-cli`, writing it alongside
the standalone one as `certs/certificates/<domain>-landmark-relative.pem`:

```sh
go run /usr/local/share/cactus/requestmtc.go -domain example.test -log http://localhost:14080/1
go run /usr/local/share/cactus/requestmtc.go -domain example.test -log ""   # skip this step
```

A freshly issued entry isn't covered by a landmark until the next one is
allocated (every `landmarks.time_between_landmarks_ms`, 60s in
`cactus-config.json`), so this step polls for up to `-landmark-wait` (default
90s). If no landmark shows up in time it warns and prints the `cactus-cli`
command to run later — the standalone cert Apache serves is unaffected either
way. To do the conversion by hand:

```sh
cactus-cli cert landmark-relative ./certs/certificates/example.test.pem http://localhost:14080/1 > lr.pem
```

## Inspect the log with cactus-cli (on the VM)

`deploy.sh` installs the `cactus-cli` debugging client to `/usr/local/bin/cactus-cli`
alongside the server binary. From the VM (or anywhere that can reach the log):

```sh
cactus-cli tree show   http://localhost:14080     # checkpoint: size + root
cactus-cli tree verify http://localhost:14080     # replay every tile, check the root
cactus-cli entry       http://localhost:14080 0   # decode a log entry
cactus-cli cert text   ./certs/example.test.pem   # human-readable view of a cert
cactus-cli cert verify ./certs/example.test.pem http://localhost:14080

# Convert a standalone cert to its landmark-relative form (prints PEM on stdout).
# Note the log number suffix (/1) — this endpoint is per-log, unlike those above:
cactus-cli cert landmark-relative ./certs/example.test.pem http://localhost:14080/1
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
- `data/` — files copied to and run on the VM (Apache configs, `setup-vm.sh`, `requestmtc.go`)
