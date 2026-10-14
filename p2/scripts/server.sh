
#!/bin/bash
set -euo pipefail

SERVER_IP="192.168.56.110"

echo "Installing K3s server..."

if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_EXEC="server --node-ip ${SERVER_IP} --advertise-address ${SERVER_IP}" \
    sh -
fi

echo "Waiting for Kubernetes API..."

until kubectl get nodes >/dev/null 2>&1; do
  sleep 2
done

echo "Waiting for Traefik Deployment to be created..."

kubectl -n kube-system wait \
  --for=create deployment/traefik \
  --timeout=300s

echo "Waiting for Traefik to become ready..."

kubectl -n kube-system rollout status \
  deployment/traefik --timeout=300s

echo "Deploying applications..."

kubectl apply -f /vagrant/confs/apps.yaml
kubectl apply -f /vagrant/confs/ingress.yaml

echo "Waiting for deployments..."

kubectl rollout status deployment/app1 --timeout=300s
kubectl rollout status deployment/app2 --timeout=300s
kubectl rollout status deployment/app3 --timeout=300s

echo "Part 2 setup finished."

kubectl get nodes
kubectl get deployments
kubectl get pods -o wide
kubectl get ingress
