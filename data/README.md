# data

Configuration files, scripts, and Go tools used by `docker-deploy.sh`.

During deployment:
- `generatemirrorindex.go` is run locally to generate the mirror index page.
- `requestmtc.go` is built locally into `out/requestmtc` and installed on the VM at `/var/lib/toolbox/bin/requestmtc`.
- Configs (`cactus-config-docker.json`, `compose.override.yaml`, `nginx.conf`) and helper scripts (`request-certs.sh`, `request-demo-domain-certs.sh`, `generate-demo-html.sh`, `run-bssl-tai.sh`) are copied to `~/docker/` on the GCP VM.
- `skylight.yaml`, `init-sunlight.sh`, and `sunlight.yaml.tmpl` are patched copies of the files of the same name in the cactus repo's `docker/` directory. `docker-deploy.sh` copies that whole directory to the VM and then drops these on top. Each carries a header comment describing its delta from upstream; re-sync them if the upstream versions change.
