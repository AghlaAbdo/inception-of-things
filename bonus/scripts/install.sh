#!/usr/bin/env bash
# Ubuntu/Debian VM prerequisites. Run with sudo; setup.sh runs as your normal user.
set -euo pipefail
[[ $(id -u) -eq 0 ]] || { echo "Run with sudo: sudo bash bonus/scripts/install.sh" >&2; exit 1; }
BONUS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Reuse the submitted Part 3 prerequisite installer rather than change it.
bash "$BONUS_DIR/../p3/scripts/install.sh"
apt-get install -y python3 openssl

# Match kubectl to the Kubernetes release bundled with k3d. Part 3's installer
# fetches stable kubectl, which may otherwise be outside the supported version skew.
kubernetes_version=$(k3d version | awk '/^k3s version/ {split($3, parts, "-"); print parts[1]}')
[[ "$kubernetes_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Could not determine k3d's Kubernetes version." >&2; exit 1;
}
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
arch=$(dpkg --print-architecture)
curl -fsSL --retry 3 "https://dl.k8s.io/release/${kubernetes_version}/bin/linux/${arch}/kubectl" -o "$task_tmp/kubectl"
curl -fsSL --retry 3 "https://dl.k8s.io/release/${kubernetes_version}/bin/linux/${arch}/kubectl.sha256" -o "$task_tmp/kubectl.sha256"
(cd "$task_tmp" && printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum --check)
install -m 0755 "$task_tmp/kubectl" /usr/local/bin/kubectl

if ! command -v helm >/dev/null || [[ $(helm version --short) != v4.* ]]; then
  case "$arch" in amd64|arm64) ;; *) echo "Unsupported Helm architecture: $arch" >&2; exit 1 ;; esac
  version=$(curl -fsSL --retry 3 https://api.github.com/repos/helm/helm/releases/latest |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
  [[ $version == v4.* ]] || { echo "Expected Helm 4, received $version" >&2; exit 1; }
  archive="helm-${version}-linux-${arch}.tar.gz"
  curl -fsSL --retry 3 "https://get.helm.sh/$archive" -o "$task_tmp/$archive"
  curl -fsSL --retry 3 "https://get.helm.sh/$archive.sha256sum" -o "$task_tmp/checksum"
  (cd "$task_tmp" && sha256sum --check checksum)
  tar -xzf "$task_tmp/$archive" -C "$task_tmp"
  install -m 0755 "$task_tmp/linux-$arch/helm" /usr/local/bin/helm
fi

# Needed only for the browser; in-cluster cloning uses Kubernetes Service DNS.
if ! python3 - <<'PY'
import pathlib, sys
found = any('gitlab.iot.test' in line.split('#', 1)[0].split()[1:]
            for line in pathlib.Path('/etc/hosts').read_text().splitlines())
sys.exit(0 if found else 1)
PY
then
  printf '\n127.0.0.1 gitlab.iot.test # Inception-of-Things local GitLab\n' >> /etc/hosts
fi
helm version --short
echo "Prerequisites ready. Run setup.sh as your normal user with Docker access."
