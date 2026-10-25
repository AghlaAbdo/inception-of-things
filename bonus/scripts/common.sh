#!/usr/bin/env bash
# Shared by entry points; all Kubernetes operations target the bonus context.
set -euo pipefail
BONUS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-iot-bonus-helm}"
CONTEXT="k3d-${CLUSTER_NAME}"
export BONUS_DIR CLUSTER_NAME CONTEXT

die() { echo "Error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Missing $1; run bonus/scripts/install.sh first."; }
kube() { kubectl --context "$CONTEXT" "$@"; }
require_cluster() {
  need kubectl
  kube get namespace gitlab >/dev/null
}
