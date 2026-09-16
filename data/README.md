# data

Configuration files, scripts, and Go tools used by `docker-deploy.sh`.

During deployment:
- `generatemirrorindex.go` is run locally to generate the mirror index page.
- `requestmtc.go` is built locally into `out/requestmtc` and installed on the VM at `/var/lib/toolbox/bin/requestmtc`.
- Configs (`cactus-config-docker.json`, `compose.override.yaml`, `nginx.conf`, `skylight.yaml`) and helper scripts (`request-certs.sh`, `request-demo-domain-certs.sh`, `generate-demo-html.sh`, `run-bssl-tai.sh`) are copied to `~/docker/` on the GCP VM.
