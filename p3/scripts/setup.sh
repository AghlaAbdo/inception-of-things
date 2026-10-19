
#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Checking Docker..."
docker info >/dev/null

echo "Creating K3d cluster..."

if ! k3d cluster list -o json | grep -q '"name": "iot"'; then
  k3d cluster create iot
fi

echo "Selecting Kubernetes context..."
kubectl config use-context k3d-iot

echo "Creating namespaces..."
kubectl create namespace argocd \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create namespace dev \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Installing Argo CD..."
kubectl apply -n argocd \
  --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for Argo CD API..."
kubectl rollout status -n argocd \
  deployment/argocd-server --timeout=600s

echo "Waiting for Application CRD..."
kubectl wait --for=condition=Established \
  crd/applications.argoproj.io \
  --timeout=180s

echo "Registering GitOps application..."
kubectl apply -f confs/application.yaml

echo "Setup complete!"
kubectl get nodes
kubectl get namespaces
kubectl get applications -n argocd
