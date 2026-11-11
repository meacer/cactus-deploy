#!/usr/bin/env bash
# Default deploy target for cactus-deploy, sourced by docker-deploy.sh.
#
# docker-deploy.sh loads VM/ZONE/PROJECT from here as its defaults. Override any of
# them per-invocation without editing this file:
#   ./docker-deploy.sh --vm=<name> --zone=<zone> --project=<gcp-project>
#   make deploy CACTUS_VM=<name> CACTUS_ZONE=<zone> CACTUS_PROJECT=<gcp-project>

VM=""           # GCP VM instance name
ZONE=""         # GCP zone the VM runs in
PROJECT=""      # GCP project ID
ENABLE_TAI="${ENABLE_TAI:-false}" # Whether to enable and serve tai.demo.mtcs.dev via bssl server
BORINGSSL_DIR="${BORINGSSL_DIR:-$HOME/src/meacer-boringssl}" # Path to meacer/boringssl tai-server branch
# Secret Manager secrets holding the cosigner seeds the deploy installs. The
# draft-05 CA's seeds stay in ca1-cosigner-seed / mirror1-cosigner-seed; point
# these back at them to redeploy that identity.
CA_SEED_SECRET="${CA_SEED_SECRET:-ca1-draft07-cosigner-seed}"
MIRROR_SEED_SECRET="${MIRROR_SEED_SECRET:-mirror1-draft07-cosigner-seed}"
