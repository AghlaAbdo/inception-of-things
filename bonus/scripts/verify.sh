#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_cluster
need python3
need curl
expected=${1:-}
[[ -z "$expected" || "$expected" == v1 || "$expected" == v2 ]] || die "Usage: verify.sh [v1|v2]"
head_revision=$(curl --noproxy '*' -fsS --max-time 15 -H 'Host: gitlab.iot.test' \
  'http://127.0.0.1/api/v4/projects/root%2Fiot-playground/repository/branches/main' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"]["id"])')

# Observe automatic reconciliation. Do not force-sync or patch the live Deployment.
echo "Waiting for Argo CD to synchronize the local GitLab commit..."
deadline=$((SECONDS + 600))
ready=false
while (( SECONDS < deadline )); do
  state=$(kube -n argocd get application playground -o json)
  if printf '%s' "$state" | python3 -c '
import json,sys
a=json.load(sys.stdin)
s=a.get("status", {})
ok=(s.get("sync", {}).get("status")=="Synced" and s.get("health", {}).get("status")=="Healthy"
    and s.get("sync", {}).get("revision")==sys.argv[1])
sys.exit(not ok)
' "$head_revision"; then
    # Requiring the requested response avoids mistaking the previous healthy revision
    # for successful deployment immediately after a GitLab commit.
    if response=$(curl --noproxy '*' -fsS --max-time 5 http://127.0.0.1:8888/) && \
      printf '%s' "$response" | python3 -c '
import json,sys
r=json.load(sys.stdin)
sys.exit(not (r.get("status")=="ok" and r.get("message") in ([sys.argv[1]] if sys.argv[1] else ["v1", "v2"])))
' "$expected"; then
      ready=true
      break
    fi
  fi
  sleep 5
done
if [[ "$ready" != true ]]; then
  kube -n argocd get application playground -o yaml >&2
  kube -n dev get pods,deployments,services >&2
  die "Timed out waiting for the GitLab deployment."
fi
kube -n dev rollout status deployment/playground --timeout=180s
kube get namespaces gitlab argocd dev
kube -n gitlab get pods,pvc
kube -n argocd get application playground
echo "Application response: $response"
echo "Synchronized GitLab commit: $head_revision"
echo "GitLab, Argo CD and application checks passed."
