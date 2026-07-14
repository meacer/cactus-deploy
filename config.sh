#!/usr/bin/env bash
# Default deploy target for cactus-deploy, sourced by deploy.sh.
#
# deploy.sh loads VM/ZONE/PROJECT from here as its defaults. Override any of
# them per-invocation without editing this file:
#   ./deploy.sh --vm=<name> --zone=<zone> --project=<gcp-project>
#   make deploy CACTUS_VM=<name> CACTUS_ZONE=<zone> CACTUS_PROJECT=<gcp-project>

VM=""           # GCP VM instance name
ZONE=""         # GCP zone the VM runs in
PROJECT=""      # GCP project ID
