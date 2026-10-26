#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
kube() { kubectl --context k3d-iot-bonus "$@"; }

for tool in docker k3d kubectl helm jq openssl; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. Run scripts/install.sh first." >&2; exit 1; }
done
docker info >/dev/null

if ! k3d cluster list -o json | jq -e '.[] | select(.name == "iot-bonus")' >/dev/null; then
  k3d cluster create iot-bonus \
    --port '127.0.0.1:80:80@loadbalancer' \
    --port '127.0.0.1:8888:30088@server:0' --wait
else
  k3d cluster start iot-bonus
  k3d kubeconfig merge iot-bonus --kubeconfig-switch-context=false >/dev/null
fi
for namespace in gitlab argocd dev; do
  kube create namespace "$namespace" --dry-run=client -o yaml | kube apply -f -
done

# Keep credentials on reruns. All dependency credentials live in one Secret.
if [[ -z $(kube -n gitlab get secret gitlab-dependencies --ignore-not-found -o name) ]]; then
  access_key="GK$(openssl rand -hex 12)"
  secret_key=$(openssl rand -hex 32)
  connection="provider: AWS
region: us-east-1
aws_access_key_id: $access_key
aws_secret_access_key: $secret_key
aws_signature_version: 4
endpoint: http://lab-s3.gitlab.svc.cluster.local:3900
path_style: true"
  kube -n gitlab create secret generic gitlab-dependencies \
    --from-literal="postgresql-password=$(openssl rand -hex 32)" \
    --from-literal="redis-password=$(openssl rand -hex 32)" \
    --from-literal="accesskey=$access_key" --from-literal="secretkey=$secret_key" \
    --from-literal="rpcsecret=$(openssl rand -hex 32)" \
    --from-literal="connection=$connection"
fi
kube apply -f confs/dependencies.yaml
for service in lab-postgresql lab-redis lab-s3; do
  kube -n gitlab rollout status "statefulset/$service" --timeout=600s
done
access_key=$(kube -n gitlab get secret gitlab-dependencies -o jsonpath='{.data.accesskey}' | base64 --decode)
for bucket in git-lfs gitlab-artifacts gitlab-uploads gitlab-packages; do
  if ! kube -n gitlab exec statefulset/lab-s3 -- /garage bucket info "$bucket" >/dev/null 2>&1; then
    kube -n gitlab exec statefulset/lab-s3 -- /garage bucket create "$bucket" >/dev/null
  fi
  kube -n gitlab exec statefulset/lab-s3 -- /garage bucket allow \
    --read --write --owner --key "$access_key" "$bucket" >/dev/null
done

helm repo add gitlab https://charts.gitlab.io --force-update
helm repo update gitlab
# A fresh install selects the latest stable chart; reruns reuse the installed version.
chart=$(helm --kube-context k3d-iot-bonus -n gitlab list --filter '^gitlab$' -o json |
  jq -r '.[0].chart // empty' | sed 's/^gitlab-//')
if [[ -z "$chart" ]]; then
  chart=$(helm search repo gitlab/gitlab -o json | jq -r '.[] | select(.name == "gitlab/gitlab") | .version')
fi
helm upgrade --install gitlab gitlab/gitlab --version "$chart" \
  --kube-context k3d-iot-bonus -n gitlab -f confs/gitlab-values.yaml \
  --timeout 30m --wait=legacy --wait-for-jobs

kube apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml
kube wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
for deployment in argocd-server argocd-repo-server argocd-redis; do
  kube -n argocd rollout status "deployment/$deployment" --timeout=600s
done
kube -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

bash scripts/bootstrap.sh
echo 'Setup complete. From the repository root, run bash bonus/scripts/access.sh.'
