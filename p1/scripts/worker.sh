
#!/bin/bash
set -euo pipefail

SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"
TOKEN_FILE="/vagrant/.cluster-token"

echo "Waiting for server join token..."

until [ -s "$TOKEN_FILE" ]; do
  sleep 2
done

TOKEN=$(cat "$TOKEN_FILE")

echo "Installing K3s agent..."

curl -sfL https://get.k3s.io | \
  K3S_URL="https://${SERVER_IP}:6443" \
  K3S_TOKEN="${TOKEN}" \
  INSTALL_K3S_EXEC="agent --node-ip ${WORKER_IP}" \
  sh -

echo "Waiting for K3s agent..."

until systemctl is-active --quiet k3s-agent; do
  sleep 2
done

echo "K3s agent installed successfully."
