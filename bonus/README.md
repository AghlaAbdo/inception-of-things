# Bonus: GitLab, Helm, and Argo CD

Four shell scripts install the lab, bootstrap the GitLab repository and Argo CD
Application, and expose the interfaces. Version changes use GitLab or normal Git
commands. No Python or API tokens are needed.

The official GitLab Helm chart requires PostgreSQL, Redis, and object storage.
Those necessary services remain in one dependency manifest. See
[IMPLEMENTATION.md](IMPLEMENTATION.md) for the concepts to explain in the defense.

## 1. Install the infrastructure

Use the project Linux VM with roughly 16 GiB RAM, 8 vCPUs, and 40 GiB free disk.
Ports 80 and 8888 must be free; Argo CD forwarding uses 8080.

From the repository root:

```sh
sudo bash bonus/scripts/install.sh
# Log out and back in if Docker group membership was just added.
bash bonus/scripts/setup.sh
```

Setup creates the **`iot-bonus`** cluster with namespaces `gitlab`, `argocd`, and
`dev`. A fresh installation selects the latest stable official GitLab chart;
reruns reuse the version recorded by the installed Helm release. Argo CD is
pinned to `v3.5.6`. First startup can take 20–30 minutes for downloads and migrations.

Setup then calls `scripts/bootstrap.sh`: it creates the public GitLab project
`root/iot-playground`, commits `app/manifests.yaml` on `main` if the repository is
empty, applies the Argo CD Application, and waits for Synced / Healthy. It uses
GitLab services through Rails runner in the webservice pod, without an API token.
Initial image downloads and synchronization can add several minutes.

## 2. Open the interfaces

```sh
bash bonus/scripts/access.sh
```

This prints both initial passwords and forwards Argo CD in the foreground. Keep
that terminal open. Use another terminal for subsequent commands.

| Interface | URL | Username |
| --- | --- | --- |
| GitLab | <http://gitlab.iot.test> | `root` |
| Argo CD | <https://localhost:8080> | `admin` |
| Playground, after deployment | <http://localhost:8888> | None |

Accept Argo CD's local certificate warning. Initial passwords work unless changed.
GitLab's hostname must resolve on the browser's machine. The installer adds
`127.0.0.1 gitlab.iot.test` to the project VM's `/etc/hosts`. If it is missing:

```sh
echo '127.0.0.1 gitlab.iot.test' | sudo tee -a /etc/hosts
```

These loopback URLs assume the browser runs on the project VM. A browser on a
different host needs SSH forwarding to the VM and its own hostname mapping.
Reinstalling Kubernetes does not fix browser-side DNS or an absent port forward.

## 3. Check the application and clone its repository

Setup has already created and deployed the application. Check it with:

```sh
kubectl --context k3d-iot-bonus -n argocd get application playground
curl http://localhost:8888/
# {"status":"ok", "message":"v1"}
```

A rerun preserves the version already committed in GitLab, so it may return v2.
Clone the generated repository into an empty directory to make version changes:

```sh
git clone http://root@gitlab.iot.test/root/iot-playground.git /tmp/iot-playground
git -C /tmp/iot-playground config user.name 'IoT Student'
git -C /tmp/iot-playground config user.email 'student@iot.local'
```

Choose another directory if `/tmp/iot-playground` already exists. Use the GitLab
`root` password when Git prompts during pushes. The example author name and email
are commit metadata; you can use your own identity.

Argo CD uses its normal polling schedule. Allow several minutes for detection
and rollout; cached repository information and image downloads can add delay.
No custom Argo CD settings or webhook are needed. Its source is the GitLab
repository's `main` branch and
`app/` directory, reached through internal Kubernetes Service DNS.

## 4. Demonstrate v1 → v2

Change the manifest **in the GitLab repository**, either through the GitLab web
editor or the working copy created above:

```sh
sed -i 's/wil42\/playground:v1/wil42\/playground:v2/' /tmp/iot-playground/app/manifests.yaml
git -C /tmp/iot-playground add app/manifests.yaml
git -C /tmp/iot-playground commit -m 'Deploy playground v2'
git -C /tmp/iot-playground push
```

Observe the new GitLab commit, Argo CD's synchronized revision, and the Pod rollout.
After Argo CD reports Synced / Healthy:

```sh
curl http://localhost:8888/
# {"status":"ok", "message":"v2"}
```

To return to v1, reverse the image change and commit/push again. Do not change the
live Deployment directly: Argo CD should obtain the desired image from Git.
Editing the original `bonus/confs/app/manifests.yaml` on disk alone does not update
the separate GitLab repository.

## Inspection and recovery

```sh
kubectl --context k3d-iot-bonus get namespaces
helm --kube-context k3d-iot-bonus -n gitlab list
kubectl --context k3d-iot-bonus -n gitlab get pods,pvc,ingress
kubectl --context k3d-iot-bonus -n argocd get application playground -o yaml
kubectl --context k3d-iot-bonus -n dev get deployment,replicaset,pod,service
```

Rerunning `setup.sh` retains dependency credentials, PVCs, the installed GitLab
chart version, and the GitLab repository. Bootstrap only seeds an empty repository;
it does not reset existing commits or overwrite version changes. An existing
project must be public and contain `app/manifests.yaml` on `main`; otherwise
bootstrap stops and explains what to fix. It does not change existing visibility.
Use its `iot-bonus` cluster name only for clusters created by this setup, since
the required host port mappings are set at cluster creation.

For startup errors, inspect Pod events and migration logs. Pending PVCs indicate
a storage provisioning problem; ImagePullBackOff concerns registry access or
an image reference. GitLab initialization needs its backends ready first.

Helm uses `--wait=legacy` so slow initial image downloads can use the full
30-minute readiness timeout instead of failing early on a Deployment's
10-minute progress deadline. If an installation already stopped with
`Progress deadline exceeded`, rerun `bash bonus/scripts/setup.sh`; keep the
existing cluster and its data.

`k3d cluster stop iot-bonus` releases runtime resources while retaining node data.
Deleting the cluster removes its local GitLab repositories and backing storage.
This is a local HTTP lab with single replicas; no automatic backup schedule is
configured. The bonus is evaluated only after the mandatory parts work correctly.

If infrastructure is already installed, run just the bootstrap from the project root:

```sh
bash bonus/scripts/bootstrap.sh
```

This is also how to retry application registration or a synchronization timeout.
A failure before synchronization finishes leaves resources in place for inspection:

```sh
kubectl --context k3d-iot-bonus -n argocd get application playground -o yaml
kubectl --context k3d-iot-bonus -n dev get pods
```

## Validation

On 2026-10-26, automatic bootstrap created the public project and initial commit,
registered the Application, and reached Synced / Healthy with an HTTP v1 response.
A full setup rerun succeeded and preserved the exact GitLab main-branch commit.
Shell syntax and whitespace checks passed.

Validated on 2026-10-25 with chart 10.5.1 / GitLab CE 19.5.1 and Argo CD 3.5.6:
fresh-cluster setup, normal password-authenticated Git pushes, automatic
v1 → v2 → v1 deployment, and HTTP 200 from both login pages. A setup rerun kept
the same dependency credentials, four PVC identities, and GitLab branch commit.
Shell syntax, YAML parsing, and Helm lint passed. The prerequisite installer was
syntax-checked; live testing used existing host tools and a temporary Helm binary.
