#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
BONUS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
bash "$BONUS_DIR/../p3/scripts/install.sh"
apt-get install -y jq openssl

task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
arch=$(dpkg --print-architecture)
# Use the kubectl release matching K3d's bundled Kubernetes server.
kubernetes_version=$(k3d version | awk '/^k3s version/ {split($3, parts, "-"); print parts[1]}')
[[ "$kubernetes_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Cannot determine K3s version.' >&2; exit 1; }
curl -fsSL --retry 3 "https://dl.k8s.io/release/$kubernetes_version/bin/linux/$arch/kubectl" -o "$task_tmp/kubectl"
curl -fsSL --retry 3 "https://dl.k8s.io/release/$kubernetes_version/bin/linux/$arch/kubectl.sha256" -o "$task_tmp/kubectl.sha256"
(cd "$task_tmp" && printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum --check)
install -m 0755 "$task_tmp/kubectl" /usr/local/bin/kubectl

if ! command -v helm >/dev/null || [[ $(helm version --short) != v4.* ]]; then
  version=$(curl -fsSL --retry 3 https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name)
  [[ "$version" == v4.* ]] || { echo "Expected Helm 4, received $version" >&2; exit 1; }
  archive="helm-$version-linux-$arch.tar.gz"
  curl -fsSL --retry 3 "https://get.helm.sh/$archive" -o "$task_tmp/$archive"
  curl -fsSL --retry 3 "https://get.helm.sh/$archive.sha256sum" -o "$task_tmp/checksum"
  (cd "$task_tmp" && sha256sum --check checksum)
  tar -xzf "$task_tmp/$archive" -C "$task_tmp"
  install -m 0755 "$task_tmp/linux-$arch/helm" /usr/local/bin/helm
fi

if ! getent hosts gitlab.iot.test >/dev/null; then
  printf '\n127.0.0.1 gitlab.iot.test\n' >> /etc/hosts
fi
echo 'Prerequisites ready. If Docker group membership changed, log out and back in.'
