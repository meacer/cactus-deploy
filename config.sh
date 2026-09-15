#!/usr/bin/env bash
# Default deploy target for cactus-deploy, sourced by deploy.sh.
#
# deploy.sh loads VM/ZONE/PROJECT from here as its defaults. Override any of
# them per-invocation without editing this file:
#   ./deploy.sh --vm=<name> --zone=<zone> --project=<gcp-project>
#   make deploy CACTUS_VM=<name> CACTUS_ZONE=<zone> CACTUS_PROJECT=<gcp-project>

VM="cactus-testing"           # GCP VM instance name
ZONE="us-central1-a"         # GCP zone the VM runs in
PROJECT="meacer"      # GCP project ID
ENABLE_TAI="${ENABLE_TAI:-true}" # Whether to enable and serve tai.demo.mtcs.dev via bssl server
BORINGSSL_DIR="${BORINGSSL_DIR:-$HOME/src/meacer-boringssl}" # Path to meacer/boringssl tai-server branch

