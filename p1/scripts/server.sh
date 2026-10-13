
#!/bin/bash
set -euo pipefail

SERVER_IP="192.168.56.110"

echo "Installing K3s server..."

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server --node-ip ${SERVER_IP} --advertise-address ${SERVER_IP} --tls-san ${SERVER_IP}" \
  sh -

echo "Waiting for K3s server to start..."

until systemctl is-active --quiet k3s; do
  sleep 2
done

until kubectl get nodes >/dev/null 2>&1; do
  sleep 2
done

# Share the generated join token with the second VM.
# This file must never be committed to Git.
cp /var/lib/rancher/k3s/server/node-token /vagrant/.cluster-token

echo "K3s server installed successfully."
kubectl get nodes -o wide
