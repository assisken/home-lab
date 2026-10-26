# Server

Just a set of kubernetes manifests running at home.
Nice and niche.

The host (`home-lab`, `192.168.1.2`) runs **Talos Linux** as a single-node
Kubernetes cluster. This directory holds the **workloads** (`apps/`,
`monitoring/`, and the Helm value files under `helm/`). The **machine config**
lives one level up at [`../talos/`](../talos/) (talhelper + patches).

## Configure the node (Talos)

From the **repo root**:

```sh
make talos-apply        # render talos/clusterconfig/ and push it (most changes need no reboot)
make talos-upgrade      # new Talos version / extensions / kernel args — reboots into it
make talos-upgrade-k8s  # bump Kubernetes to kubernetesVersion in talconfig.yaml
```

The node has no shell and no SSH: `talosctl` (port 50000) is the only admin
path. The from-scratch runbook (in Russian) is [`../README.md`](../README.md).

## Deploy the workloads (Kubernetes)

The tree is a [Kustomize](https://kustomize.io/) overlay — every app and
monitoring component has its own `kustomization.yaml`, aggregated by
`apps/`, `monitoring/`, and the root `kustomization.yaml`. Kustomize ships
inside `kubectl`, so there is nothing extra to install.

```sh
kubectl kustomize .          # render everything locally, no cluster contact
kubectl diff -k .            # what would change on the cluster
kubectl apply -k .           # apply the whole tree
kubectl apply -k apps/jellyfin   # or just one service
```

`kubectl diff -k .` is the useful one: before Kustomize there was no way to
tell whether this repo matched the cluster.

Adding a service means creating `apps/<name>/`, listing its objects in a
`apps/<name>/kustomization.yaml`, and adding `<name>` to
`apps/kustomization.yaml`. `server/validate.sh` skips `kustomization.yaml`
itself — it is a Kustomize file, not a Kubernetes object with a schema.

Two deliberate omissions in the root overlay:

- **No `commonLabels`/`labels` transformer.** Kustomize's `commonLabels` also
  rewrites `spec.selector`, and selectors are immutable on existing
  Deployments — adding one would make every apply fail.
- **No `images:` transformer.** Image versions are pinned inline in each
  manifest instead, so `grep -r 'image:'` tells the truth and the per-directory
  `kubectl apply -f apps/<service>/` path keeps working.

`helm/` is not referenced by the overlay: those components are Helm releases,
pinned in [`helmfile.yaml`](helmfile.yaml) (see below).

### NodePort allocations

Ports are hand-assigned; a duplicate makes the second Service fail to apply.
Check this table before adding one.

Web UIs are not NodePorts: they are `https://<app>.l.example.com`
(intranet-only, see `apps/intranet`). The NodePorts are for clients that are
not browsers. Each one is also listed in the host firewall
(`../talos/patches/firewall.yaml`), which opens these ports, not a range.

| Port  | Service     | Why it is a NodePort                    |
|-------|-------------|-----------------------------------------|
| 30003 | suwayomi    | Mihon/Tachiyomi clients may point at it |
| 30006 | deluge      | daemon RPC (58846) for thin clients     |
| 30008 | jellyfin    | TV/phone apps may point at it           |

## Helm components

Helm-based components (`sealed-secrets`, `cilium`, `traefik`, `homarr`) keep
their value files under `helm/<name>/values.yml`. The chart sources, versions
and value paths are pinned in [`helmfile.yaml`](helmfile.yaml) and resolved
into [`helmfile.lock`](helmfile.lock).

```sh
helmfile apply                    # every release
helmfile -l name=traefik apply    # just one
helmfile deps                     # re-resolve helmfile.lock after changing a version
```

On a fresh cluster, install `cilium` first (nothing schedules without a CNI),
then `sealed-secrets` — anything with sealed credentials stays in
`CreateContainerConfigError` until its Secret exists. `make cluster-up` in
the repo root does the whole order.

## Validating before you apply

Everything here is applied by hand, so the only safety net is an offline check.
`server/validate.sh` (run it inside `make shell`, so the tool versions match the
Dockerfile) never contacts a cluster:

```sh
make server-validate   # kubeconform, strict, over apps/ + monitoring/
make server-helm       # helmfile template + kubeconform of the rendered charts
```

`server-helm` needs the upstream chart repos to be reachable — run it before a
`helmfile apply`.

## Secrets

Credentials are **Bitnami SealedSecrets** — encrypted blobs that are safe to
commit and that only the controller in this cluster can decrypt. Full runbook,
including how to back up the controller's sealing key: [`SECRETS.md`](SECRETS.md).

```sh
make -C server help               # list every managed secret
make -C server seal-sonarr        # secrets-unsealed/sonarr.yaml -> apps/sonarr/sonarr-sealedsecret.yaml
kubectl apply -k apps/sonarr
```

The cleartext inputs live in `secrets-unsealed/` and are **gitignored**; the
sealed `*-sealedsecret.yaml` files next to each app are what gets committed and
applied. This repo ships **no** sealed files: they are bound to the controller
key of one cluster. `scripts/init-secrets.sh` writes the cleartext inputs from
the `secrets-unsealed/*.yaml.example` templates.

One thing in `SECRETS.md` is not optional reading: **back up the sealing key**
(`make -C server backup-key`). Lose it and every committed sealed file is
undecryptable.
