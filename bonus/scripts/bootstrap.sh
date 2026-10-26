#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
kube() { kubectl --context k3d-iot-bonus "$@"; }

# Use GitLab's installed services: no password, API token, or toolbox pod needed.
kube -n gitlab wait --for=condition=Available deployment/gitlab-webservice-default --timeout=600s
{
  printf "seed = Base64.decode64('%s')\n" "$(base64 -w0 confs/app/manifests.yaml)"
  cat <<'RUBY'
root = User.find_by_username!('root')
project = Project.find_by_full_path('root/iot-playground')
unless project
  project = Projects::CreateService.new(root, {
    name: 'iot-playground', path: 'iot-playground',
    namespace_id: root.namespace_id, visibility_level: Gitlab::VisibilityLevel::PUBLIC
  }).execute
  abort("Project creation failed: #{project.errors.full_messages.join(', ')}") unless project.persisted?
end
abort('Existing root/iot-playground must be public for Argo CD to read it.') unless project.public?

if project.empty_repo?
  result = Files::CreateService.new(project, root, {
    branch_name: 'main', commit_message: 'Deploy playground v1',
    file_path: 'app/manifests.yaml', file_content: seed
  }).execute
  abort("Initial commit failed: #{result[:message]}") unless result[:status] == :success
  puts 'Created initial playground commit on main.'
else
  abort('Existing repository needs app/manifests.yaml on main; existing commits were preserved.') unless
    project.repository.blob_at('main', 'app/manifests.yaml')
  puts 'Preserved existing playground repository and commits.'
end
puts "Repository ready: #{project.full_path}"
RUBY
} | kube -n gitlab exec -i deployment/gitlab-webservice-default -c webservice -- \
  /srv/gitlab/bin/rails runner -e production -

kube apply -f confs/application.yaml
kube -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/playground --timeout=600s
kube -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/playground --timeout=600s
echo 'Playground ready: http://localhost:8888/'
