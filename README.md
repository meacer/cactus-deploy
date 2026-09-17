# cactus-deploy

Deploy scripts for the containerized cactus MTC CA stack (`cactus`, `sunlight`,
`skylight`, `nginx`, `certbot`) on a GCP VM.

Everything runs on your **local machine** unless a section says otherwise.

## Quick start

**1. Install Go 1.27+.** No release exists yet, so use `gotip`:

```sh
go install golang.org/dl/gotip@latest
export PATH="$PATH:$HOME/go/bin"
gotip download
```

**2. Clone cactus and build the images.** `docker-deploy.sh` ships these to the
VM but does not build them:

```sh
git clone https://github.com/mcpherrinm/cactus.git ~/src/mcpherrinm-cactus
make -C ~/src/mcpherrinm-cactus docker-build
```

**3. Set your deploy target**, then edit `VM`, `ZONE`, and `PROJECT`:

```sh
cp config.example.sh config.sh
```

**4. Create the VM** (skip if it already exists). It **must** be Container-Optimized
OS — `--image-family=cos-stable --image-project=cos-cloud`:

```sh
gcloud compute instances create cactus-testing \
    --zone=us-central1-a --project=meacer \
    --machine-type=e2-standard-2 \
    --image-family=cos-stable --image-project=cos-cloud
```

> [!IMPORTANT]
> Do not substitute Debian or Ubuntu. COS ships Docker preinstalled and has a
> read-only `/usr`, so the deploy installs every binary (`cactus-cli`,
> `requestmtc`, `docker-compose`, `lego`, `bssl`) to `/var/lib/toolbox/bin`.
> That path is COS-specific, and it is hardcoded throughout `docker-deploy.sh`
> and in the commands below.

**5. Deploy:**

```sh
make setup     # first time only — also creates the GCP firewall rules
make deploy    # every time after
```

You need no key material locally: the cosigner seeds are pulled from GCP Secret
Manager at deploy time and installed into the VM's Docker volumes.

> [!IMPORTANT]
> Nothing checks that your cactus checkout is current. After an upstream change,
> re-run step 2 (`git -C ~/src/mcpherrinm-cactus pull --ff-only` and
> `make ... docker-build`) or you will silently deploy an old cactus.

## Configuration

| Setting | Default | Purpose |
| --- | --- | --- |
| `VM` / `ZONE` / `PROJECT` | from `config.sh` | deploy target |
| `CACTUS_DIR` | `~/src/mcpherrinm-cactus` | cactus checkout to build from |
| `BORINGSSL_DIR` | `~/src/meacer-boringssl` (`tai-server` branch) | only for the TAI demo site; offered as a clone if missing |
| `ENABLE_TAI` | `true` | serve `tai.demo.mtcs.dev` |

Override per run instead of editing `config.sh`:

```sh
make deploy CACTUS_PROJECT=myproject CACTUS_VM=my-vm CACTUS_ZONE=us-east1-b
./docker-deploy.sh --vm=my-vm --zone=us-east1-b --project=myproject
./docker-deploy.sh --enable-tai            # or --disable-tai
./docker-deploy.sh --setup-firewall        # what `make setup` adds
CACTUS_DIR=~/src/my-cactus-fork ./docker-deploy.sh   # deploy an unlanded patch
```

`make setup` opens tcp:22,80,443 plus the stack's ports — 14000 (ACME), 14080
(monitoring/tiles), 14090 (metrics), 8080 (sunlight), 8081 (skylight) — scoped
to the VM's service account.

## Request an MTC certificate (on the VM)

`requestmtc` requests a certificate from the local ACME server, writes an Nginx
vhost to `~/docker/sites-enabled/<domain>.conf`, and reloads `cactus-nginx-1`.
Certificates land in `~/docker/certs/certificates`. A timer renews the demo
certificates every Monday and Thursday.

```sh
gcloud compute ssh cactus-testing --zone=us-central1-a --project=meacer
cd ~/docker

/var/lib/toolbox/bin/requestmtc -domain example.test
/var/lib/toolbox/bin/requestmtc -domain example.test -email me@example.com
```

`-relative` converts the cert to its landmark-relative form (draft §6.3.3) and
uses that in the vhost; add `-tai` to attach the TAI `CERTIFICATE PROPERTIES`
block (`11129.11.99.1.1.1.<landmarkNumber>`):

```sh
/var/lib/toolbox/bin/requestmtc -domain example.test -relative
/var/lib/toolbox/bin/requestmtc -domain example.test -relative -tai
```

## Inspect the log (on the VM)

```sh
/var/lib/toolbox/bin/cactus-cli tree show   http://localhost:14080   # checkpoint: size + root
/var/lib/toolbox/bin/cactus-cli tree verify http://localhost:14080   # replay every tile
/var/lib/toolbox/bin/cactus-cli entry       http://localhost:14080 0 # decode an entry
/var/lib/toolbox/bin/cactus-cli cert text   ./certs/certificates/example.test.crt
/var/lib/toolbox/bin/cactus-cli cert verify ./certs/certificates/example.test.crt http://localhost:14080

# Note the /1 suffix — this endpoint is per-log, unlike those above:
/var/lib/toolbox/bin/cactus-cli cert landmark-relative ./certs/certificates/example.test.crt http://localhost:14080/1
```

## Destructive operations

**Wipe the log state** (on the VM). Deletes the log, tiles, checkpoints, and the
cosigner seeds in the volumes. Seeds are restored from Secret Manager on the
next deploy; everything else is gone. Run `./docker-deploy.sh` afterwards to
recreate the volumes.

```sh
cd ~/docker
/var/lib/toolbox/bin/docker-compose -f compose.yaml -f compose.override.yaml down
docker volume rm cactus_cactus-data cactus_sunlight-data
```

**Start a new CA identity** (local). Generates fresh CA and witness cosigner
keys into `keys/`, replacing the existing ones. You do not need this to deploy —
only to stand up a CA with a new identity.

```sh
./cactus-reset.sh
```

**Delete the VM:**

```sh
gcloud compute instances delete cactus-testing --zone=us-central1-a --project=meacer
```

## Files

- `docker-deploy.sh` — builds the tools and deploys the stack
- `config.example.sh` → copy to `config.sh` (gitignored) for your deploy target
- `cactus-reset.sh` — generates a fresh CA identity
- `download-keys.sh` — downloads cosigner seeds from Secret Manager
- `print-mirror-vkey.sh` — prints the live Sunlight mirror SPKI public key
- `keys/` — cosigner seeds and public keys (gitignored)
- `data/` — configs, helper scripts, and Go tools copied to the VM. Three files
  (`skylight.yaml`, `init-sunlight.sh`, `sunlight.yaml.tmpl`) override the cactus
  repo's `docker/` copies at deploy time; each has a header explaining the delta.
- `make clean` removes built binaries and generated pages (`out/`)
