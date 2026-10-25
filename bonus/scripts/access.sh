#!/usr/bin/env bash
set -euo pipefail
kube() { kubectl --context k3d-iot-bonus "$@"; }
echo 'GitLab: http://gitlab.iot.test | username: root | initial password:'
kube -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 --decode
printf '\n\nArgo CD: https://localhost:8080 | username: admin | initial password:\n'
kube -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode
printf '\n\nKeep this terminal open for Argo CD. Ctrl-C stops the forwarding.\n'
kube -n argocd port-forward --address 127.0.0.1 service/argocd-server 8080:443
