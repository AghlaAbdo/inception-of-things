# Bonus: GitLab, Helm, and Argo CD

Three shell scripts install the lab and expose its interfaces. Repository creation
and version changes use GitLab and normal Git commands. There is no Python, API
token automation, shared shell library, or custom verification script.

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

Setup stops after installing the infrastructure. The next two sections create
the deployment source and register it with Argo CD.

## 2. Open the interfaces and create the GitLab project

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

In GitLab, choose **New project → Create blank project**:

- Project name/path: **`iot-playground`**.
- Namespace: **`root`**.
- Visibility: **Public**.
- Leave **Initialize repository with a README** unchecked.

The resulting project is `root/iot-playground`. Public visibility allows Argo CD
to fetch it without GitLab credentials. This manual step replaces the previous
Python/Rails/API bootstrap automation.

If the project already exists, reuse it. Clone it into an empty working directory
with `git clone http://root@gitlab.iot.test/root/iot-playground.git /tmp/iot-playground`
and skip the initial commit/push block below; continue with application registration
and the version-change demonstration.

## 3. Push the application and register Argo CD

Use a fresh directory for the GitOps repository. The following example uses
`/tmp/iot-playground`; choose another empty directory if that path already exists.
Run from the project repository root:

```sh
mkdir -p /tmp/iot-playground/app
cp bonus/confs/app/manifests.yaml /tmp/iot-playground/app/
git -C /tmp/iot-playground init -b main
git -C /tmp/iot-playground config user.name 'IoT Student'
git -C /tmp/iot-playground config user.email 'student@iot.local'
git -C /tmp/iot-playground remote add origin http://root@gitlab.iot.test/root/iot-playground.git
git -C /tmp/iot-playground add app
git -C /tmp/iot-playground commit -m 'Deploy playground v1'
git -C /tmp/iot-playground push -u origin main
```

Use the GitLab `root` password when Git prompts. The example author name/email are
Git commit metadata; they do not create a GitLab account. You can use your own
author identity. Keep credentials out of remote URLs and repository files.

Then register the application:

```sh
kubectl --context k3d-iot-bonus apply -f bonus/confs/application.yaml
kubectl --context k3d-iot-bonus -n argocd get application playground -w
```

Wait for **Synced / Healthy**, then Ctrl-C the watch and check:

```sh
curl http://localhost:8888/
# {"status":"ok", "message":"v1"}
```

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
chart version, and the GitLab repository. It does not push files or reset commits.
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

## Validation

Validated on 2026-10-25 with chart 10.5.1 / GitLab CE 19.5.1 and Argo CD 3.5.6:
fresh-cluster setup, normal password-authenticated Git pushes, automatic
v1 → v2 → v1 deployment, and HTTP 200 from both login pages. A setup rerun kept
the same dependency credentials, four PVC identities, and GitLab branch commit.
Shell syntax, YAML parsing, and Helm lint passed. The prerequisite installer was
syntax-checked; live testing used existing host tools and a temporary Helm binary.
