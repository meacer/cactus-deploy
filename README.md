# cactus-deploy

Deploy scripts for the cactus MTC CA server on GCP VM `https-testing`.

## Fresh VM

```sh
./cactus-reset.sh       # generate CA + witness keys (only needed once)
make setup              # install packages, certbot, deploy binary + configs
```

## Subsequent deploys

```sh
make deploy             # build + deploy to VM
```

## Other commands

```sh
make                    # just build the Linux binary (no deploy)
make clean              # remove cloned source and built binary
```

## Files

- `cactus-config.json` — cactus app config
- `apache.conf` — Apache vhost config (all domains)
- `cactus.service` — systemd unit
- `keys/` — cosigner seeds (secret) and public keys
