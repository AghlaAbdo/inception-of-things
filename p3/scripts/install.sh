
#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script with sudo."
  exit 1
fi

echo "Installing prerequisites..."
apt-get update
apt-get install -y ca-certificates curl git

echo "Checking Docker..."

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Installing Docker..."
  apt-get install -y docker.io
else
  echo "Docker is already installed."
fi

systemctl enable --now docker
docker info >/dev/null

echo "Checking kubectl..."

if ! command -v kubectl >/dev/null 2>&1; then
  ARCH=$(dpkg --print-architecture)

  K8S_VERSION=$(curl \
    --fail --silent --show-error \
    --retry 5 --retry-all-errors \
    --retry-delay 3 \
    https://dl.k8s.io/release/stable.txt)

  echo "Installing kubectl ${K8S_VERSION}..."

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  curl -fL --retry 5 --retry-all-errors \
    "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl" \
    -o "$TMP_DIR/kubectl"

  curl -fL --retry 5 --retry-all-errors \
    "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl.sha256" \
    -o "$TMP_DIR/kubectl.sha256"

  (
    cd "$TMP_DIR"
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
  )

  install -m 0755 "$TMP_DIR/kubectl" /usr/local/bin/kubectl
else
  echo "kubectl is already installed."
fi

echo "Checking k3d..."

if ! command -v k3d >/dev/null 2>&1; then
  curl -fsSL --retry 5 \
    https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
    | bash
else
  echo "k3d is already installed."
fi

echo "Configuring Docker permissions..."

TARGET_USER="${SUDO_USER:-}"

if [[ -n "$TARGET_USER" ]]; then
  usermod -aG docker "$TARGET_USER"
fi

echo "Installation complete."

docker --version
kubectl version --client
k3d version

echo "Log out and back in to activate Docker permissions."
