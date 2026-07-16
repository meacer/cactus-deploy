# data

Files here aren't used on your local machine — `deploy.sh` copies them to the
GCP VM and they're installed/run there (Apache configs, VM setup script,
`requestmtc.go`).

`requestmtc.go` is installed to `/usr/local/share/cactus/requestmtc.go` and run
from source on the VM with `go run` (see the top-level README).
