#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ $# -eq 1 && ( "$1" == v1 || "$1" == v2 ) ]] || die "Usage: set-version.sh v1|v2"
require_cluster
python3 "$BONUS_DIR/scripts/gitlab.py" version "$1"
bash "$BONUS_DIR/scripts/verify.sh" "$1"
