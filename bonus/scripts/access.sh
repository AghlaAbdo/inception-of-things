#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_cluster
echo 'GitLab: http://gitlab.iot.test (username: root)'
echo 'GitLab initial password (if unchanged):'
kube -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 --decode
printf '\n\nArgo CD: https://localhost:8080 (username: admin)\n'
echo 'Argo CD initial password (if unchanged):'
kube -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode
printf '\n\nPlayground: http://localhost:8888\n'
echo 'Forwarding Argo CD to localhost:8080; Ctrl-C stops the forwarding.'
kube -n argocd port-forward --address 127.0.0.1 service/argocd-server 8080:443
