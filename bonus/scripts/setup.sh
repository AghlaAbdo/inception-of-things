#!/usr/bin/env bash
# Complete local bonus installation; no Vagrant and no dependency on p3's cluster.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
for tool in docker k3d kubectl helm python3 curl; do need "$tool"; done
docker info >/dev/null
[[ $(helm version --short) == v4.* ]] || die "Helm 4 required; run install.sh."

if ! k3d cluster list -o json | python3 -c \
  'import json,os,sys; sys.exit(not any(c["name"] == os.environ["CLUSTER_NAME"] for c in json.load(sys.stdin)))'; then
  echo "Creating $CLUSTER_NAME (GitLab localhost:80, playground localhost:8888)..."
  k3d cluster create "$CLUSTER_NAME" --servers 1 --agents 0 \
    --port '127.0.0.1:80:80@loadbalancer' \
    --port '127.0.0.1:8888:30088@server:0' \
    --kubeconfig-switch-context=false --wait
else
  k3d cluster start "$CLUSTER_NAME"
  k3d kubeconfig merge "$CLUSTER_NAME" --kubeconfig-switch-context=false >/dev/null
fi
python3 - <<'PY'
import json, os, subprocess
name = os.environ['CLUSTER_NAME']
result = subprocess.run(['docker', 'inspect', f'k3d-{name}-serverlb', f'k3d-{name}-server-0'],
                        capture_output=True, text=True, check=True)
# K3d 5.9 proxies node mappings through serverlb; earlier versions bind directly.
nodes = json.loads(result.stdout)
for container_port, host_port in [('80/tcp', '80'), ('30088/tcp', '8888')]:
    bindings = [b for node in nodes
                for b in (node['HostConfig']['PortBindings'] or {}).get(container_port, []) or []]
    if not any(b.get('HostIp') == '127.0.0.1' and b['HostPort'] == host_port
               for b in bindings):
        raise SystemExit(f'Existing cluster lacks the required localhost:{host_port} mapping. '
                         'Use a fresh CLUSTER_NAME with setup.sh.')
PY
kube wait --for=condition=Ready nodes --all --timeout=180s
# Existing clusters must have been created with the port mappings above.
for namespace in gitlab argocd dev; do
  kube create namespace "$namespace" --dry-run=client -o yaml | kube apply -f -
done

echo "Resolving releases from the official repositories..."
helm repo add gitlab https://charts.gitlab.io --force-update
helm repo update gitlab
recorded_chart=$(kube -n gitlab get configmap bonus-versions --ignore-not-found \
  -o jsonpath='{.data.gitlabChart}')
recorded_argo=$(kube -n gitlab get configmap bonus-versions --ignore-not-found \
  -o jsonpath='{.data.argoCD}')
chart_version=${GITLAB_CHART_VERSION:-$recorded_chart}
if [[ -z "$chart_version" ]]; then
  chart_version=$(helm search repo gitlab/gitlab -o json |
    python3 -c 'import json,sys; print(next(c["version"] for c in json.load(sys.stdin) if c["name"] == "gitlab/gitlab"))')
fi
argo_version=${ARGOCD_VERSION:-$recorded_argo}
if [[ -z "$argo_version" ]]; then
  argo_version=$(curl -fsSL --retry 3 https://api.github.com/repos/argoproj/argo-cd/releases/latest |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
fi
[[ "$chart_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid GitLab chart version."
[[ "$argo_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid Argo CD version."
if [[ -n "$recorded_chart" && "$recorded_chart" != "$chart_version" ]]; then
  die "Existing GitLab uses chart $recorded_chart. Follow GitLab's supported upgrade path before changing versions."
fi
kube -n gitlab create configmap bonus-versions \
  --from-literal="gitlabChart=$chart_version" --from-literal="argoCD=$argo_version" \
  --dry-run=client -o yaml | kube apply -f -
echo "GitLab chart $chart_version; Argo CD $argo_version (recorded for repeat runs)."

python3 "$BONUS_DIR/scripts/credentials.py"
kube apply -f "$BONUS_DIR/confs/dependencies.yaml"
for service in lab-postgresql lab-redis lab-s3; do
  kube -n gitlab rollout status "statefulset/$service" --timeout=600s
done
# The server bootstraps its single-node layout and S3 key from Secret-backed env.
# These CLI operations add only missing buckets and restore the key permissions.
access_key=$(kube -n gitlab get secret lab-s3 -o jsonpath='{.data.accesskey}' | base64 --decode)
for bucket in git-lfs gitlab-artifacts gitlab-uploads gitlab-packages gitlab-backups tmp; do
  if ! kube -n gitlab exec statefulset/lab-s3 -- /garage bucket info "$bucket" >/dev/null 2>&1; then
    kube -n gitlab exec statefulset/lab-s3 -- /garage bucket create "$bucket" >/dev/null
  fi
  kube -n gitlab exec statefulset/lab-s3 -- /garage bucket allow \
    --read --write --owner --key "$access_key" "$bucket" >/dev/null
done

echo "Installing GitLab via the official Helm chart (first boot may take 20 minutes)..."
helm upgrade --install gitlab gitlab/gitlab --version "$chart_version" \
  --kube-context "$CONTEXT" --namespace gitlab \
  --values "$BONUS_DIR/confs/gitlab-values.yaml" \
  --timeout 30m --wait --wait-for-jobs
kube -n gitlab rollout status deployment/gitlab-webservice-default --timeout=600s
kube -n gitlab rollout status deployment/gitlab-toolbox --timeout=300s

echo "Installing Argo CD..."
kube apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${argo_version}/manifests/install.yaml"
kube apply --server-side --field-manager=iot-bonus-config --force-conflicts \
  -f "$BONUS_DIR/confs/argocd-config.yaml"
kube wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
for deployment in argocd-server argocd-repo-server argocd-redis; do
  kube -n argocd rollout status "deployment/$deployment" --timeout=600s
done
kube -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

echo "Creating the public local GitLab repository and seeding its manifests..."
python3 "$BONUS_DIR/scripts/gitlab.py" seed
kube apply -f "$BONUS_DIR/confs/application.yaml"
bash "$BONUS_DIR/scripts/verify.sh"
echo "Setup complete. GitLab: http://gitlab.iot.test ; application: http://localhost:8888"
echo "Run bonus/scripts/access.sh for credentials and the Argo CD UI."
