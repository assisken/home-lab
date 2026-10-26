# Secrets on `home-lab`

Kubernetes credentials for this cluster are stored as **Bitnami SealedSecrets**:
asymmetrically encrypted blobs that are safe to commit, and that only the
controller running in this cluster can decrypt.

> This is the **Kubernetes** side only. The Talos machine secrets
> (`talos/talsecret.yaml`) are a plain, git-ignored file: see the top-level
> README.md, step 1.

## How it works

```
secrets-unsealed/sonarr.yaml       cleartext Secret       gitignored, local only
        │
        │  kubeseal  (encrypts with the controller's PUBLIC key)
        ▼
apps/sonarr/sonarr-sealedsecret.yaml   SealedSecret       committed
        │
        │  kubectl apply  →  controller decrypts with its PRIVATE key
        ▼
Secret default/sonarr                  in-cluster          never leaves the node
```

Three properties that follow from this, and that drive everything below:

- **Sealing needs only the public key.** You can seal from your workstation, offline,
  with no kube context — see `make fetch-cert`.
- **Unsealing needs the controller's private key, which exists only on
  home-lab.** Lose it and every committed `*-sealedsecret.yaml` is landfill.
  [Back it up.](#back-up-the-sealing-key)
- **Sealing is strict by default**: a blob sealed for `default/sonarr` will not
  decrypt as `other-ns/sonarr` or `default/sonarr-2`. Renaming a Secret means
  resealing it.


## Layout

| Path | Tracked? | What |
|------|----------|------|
| `secrets-unsealed/<slug>.yaml` | **no** (gitignored) | cleartext `Secret` — the input to `kubeseal` |
| `secrets-unsealed/README.md` | yes | rules for that directory |
| `secrets-unsealed/sealing-cert.pem` | **no** | controller public key, for offline sealing (harmless, just kept out of git) |
| `<dir>/<slug>-sealedsecret.yaml` | yes | the sealed output — **this is what gets applied** |
| `<dir>/<slug>-sealedsecret.yaml.example` | yes | placeholder describing the sealed file that belongs there |
| `<dir>/kustomization.yaml` | yes | must list `<slug>-sealedsecret.yaml` under `resources:`, or it is never applied |
| `helm/sealed-secrets/values.yml` | yes | controller chart values |
| `Makefile` | yes | `seal`, `fetch-cert`, `backup-key`, … |

The `.yaml.example` stubs exist so the tracked tree still shows what belongs in
each app directory before anything has been sealed. Two things keep a stub from
ever reaching the cluster: it is not listed in its directory's
`kustomization.yaml` (Kustomize applies exactly what `resources:` names, so an
unlisted file is invisible to `kubectl apply -k`), and the extension is not one
`kubectl apply -f`/`-Rf` reads — those take only `.yaml`, `.yml` and `.json`.
Either way a placeholder cannot be applied by accident and blank out a live
Secret.

Managed secrets (`make -C server help` prints this list):

| slug | Secret | consumed by |
|------|--------|-------------|
| `lidarr` | `default/lidarr` | `apps/lidarr` — exportarr `APIKEY` |
| `sonarr` | `default/sonarr` | `apps/sonarr` — exportarr `APIKEY` |
| `prowlarr` | `default/prowlarr` | `apps/prowlarr` — exportarr `APIKEY` |
| `suwayomi` | `default/suwayomi` | `apps/suwayomi` — `AUTH_USERNAME` / `AUTH_PASSWORD` |
| `grafana-admin` | `default/grafana-admin` | `monitoring/grafana` — local admin of a fresh database |
| `db-encryption` | `default/db-encryption` | the homarr chart — `SECRET_ENCRYPTION_KEY` |
| `cloudflare` | `kube-system/cloudflare` | `helm/traefik/values.yml` — `CF_DNS_API_TOKEN` |

## Install the controller

The controller is a Helm release pinned in [`helmfile.yaml`](helmfile.yaml)
alongside cilium/traefik/homarr. On a fresh cluster install it **first** —
every workload whose credentials are sealed will sit in
`CreateContainerConfigError` until the controller has produced its Secret.

```sh
make -C server install-controller     # helm upgrade --install, kube-system
```

or, equivalently, through helmfile:

```sh
helmfile -l name=sealed-secrets apply
```

You also need the `kubeseal` client locally. It must be **no newer than** the
controller (an older client is fine; a newer one may emit a format the
controller does not understand yet):

The tools image (`make shell`) pins it to the controller's version:

```sh
kubeseal --version
kubectl -n kube-system get deploy sealed-secrets-controller
```

The chart values set `fullnameOverride: sealed-secrets-controller` in
`kube-system`, which is exactly what `kubeseal` looks for by default — so the
CLI works with no flags. The `Makefile` passes `--controller-name` /
`--controller-namespace` explicitly anyway, so that a rename on the chart side
fails loudly instead of silently sealing against the wrong thing.

Verify the CRD landed:

```sh
kubectl get crd sealedsecrets.bitnami.com
```


## Seal a secret

One command per secret:

```sh
make -C server seal-sonarr
```

That reads `server/secrets-unsealed/sonarr.yaml`, encrypts it, and writes
`server/apps/sonarr/sonarr-sealedsecret.yaml` (with a generated-file banner).
`make -C server seal` does all of them.

### Sealing offline

You do not even need a kube context to seal. Fetch the controller's **public** cert
once — from the node, or from anywhere that can reach the cluster — and then
seal with no cluster access at all:

```sh
make -C server fetch-cert                                       # needs the cluster, once
make -C server seal CERT=secrets-unsealed/sealing-cert.pem      # needs nothing
```

Re-fetch the cert after a key renewal (see below). Sealing against a stale cert
is not dangerous — the controller keeps every key it has ever had and will still
decrypt — it just means new seals use an old key.

### Then apply it

```sh
kubectl apply -k server/apps/sonarr
kubectl -n default get sealedsecret sonarr        # SYNCED?
kubectl -n default get secret sonarr              # did the Secret appear?
```

If the Secret does not appear, the controller logs say why (wrong namespace,
sealed against a key it does not have):

```sh
kubectl -n kube-system logs deploy/sealed-secrets-controller
```

Pods do **not** pick up a changed Secret in `env.valueFrom` — that is read once
at container start. Restart the consumer after resealing:

```sh
kubectl -n default rollout restart deploy/sonarr
```

### Commit it

```sh
make -C server check-cleartext        # guard: no cleartext Secret in the tracked tree
git add server/apps/sonarr/sonarr-sealedsecret.yaml
git commit
```

`make seal` (all) re-encrypts with a fresh random session key each run, so every
sealed file changes even when its cleartext did not. Prefer `make seal-<slug>`
for the one secret you actually edited, to keep diffs meaningful.


## Back up the sealing key

**Do this immediately after installing the controller, and again after every key
renewal.** This is the single point of failure in the whole scheme.

The controller generates an RSA keypair and stores it in a `Secret` in
`kube-system` labelled `sealedsecrets.bitnami.com/sealed-secrets-key=active`.
The private half never leaves the cluster and is not in git. If the node's etcd
is lost — reinstall, disk failure — a fresh
controller comes up with a **brand new** keypair and **every committed
`*-sealedsecret.yaml` becomes permanently undecryptable.**

Recovery without the key backup means retyping every credential from
`secrets-unsealed/` — which is precisely the copy that is *not* in git, lives
only on one laptop, and is not part of any backup either. So: back up the key.

```sh
make -C server backup-key
```

That writes `server/secrets-unsealed/sealing-key-backup.yaml`. It contains a
**cleartext RSA private key**. It is written into the gitignored directory only
so it cannot be committed by reflex — that is not storage.

Move it somewhere durable and encrypted — a password manager that does **not**
run on this cluster, plus a copy on offline media — then delete the local copy
(`shred -u`). Do **not** commit it anywhere in this repo: it is the master key
for every sealed file.

Sanity-check the backup is a real key and not an empty list before you delete
the original:

```sh
grep -c 'tls.key' server/secrets-unsealed/sealing-key-backup.yaml   # expect >= 1
```


## Restore the key on a rebuilt cluster

Restore the backed-up keys **before** installing the controller (or restart it
afterwards — it only reads keys at startup):

```sh
kubectl apply -f sealing-key-backup.yaml
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
kubectl apply -k server
```

If the key is genuinely gone, there is no decryption path. Reseal from
`secrets-unsealed/` instead — and treat anything you cannot find there as a
credential to regenerate at the source (see each `.yaml.example` in `secrets-unsealed/` for where each one comes from).

## Key renewal

`keyrenewperiod: "720h"` (30 days) in `helm/sealed-secrets/values.yml` makes the
controller mint a new keypair monthly. This is additive, not a rotation: old
keys are retained and still decrypt everything sealed with them, so **already
committed files keep working and do not need resealing**. Only new seals use the
new key.

The practical consequences:

- the key backup goes stale — re-run `make -C server backup-key` after a renewal,
  or the newest keys are unprotected;
- `secrets-unsealed/sealing-cert.pem` goes stale — re-run `make -C server
  fetch-cert` if you want new seals on the current key.


## The one Secret outside `default`

`cloudflare` (key `token`, sealed to `helm/traefik/cloudflare-sealedsecret.yaml`)
lives in **kube-system**, next to Traefik, which reads it as `CF_DNS_API_TOKEN`
for Let's Encrypt DNS-01. The root kustomization forces `namespace: default`,
so it is not part of `kubectl apply -k server`; apply it with `kubectl apply -f`.

## Add a new secret

1. Write the cleartext `Secret` to `secrets-unsealed/<slug>.yaml`. Set
   `metadata.namespace: default` explicitly — sealing is namespace-strict, and
   leaving it off makes the result depend on whatever your kube context's
   current namespace happened to be. Prefer `stringData:`.
2. Add `<slug>:<destination dir>` to `SECRETS` in the [`Makefile`](Makefile).
3. Drop a `<slug>-sealedsecret.yaml.example` stub in that directory, modelled on
   the existing ones, so the tracked tree shows what belongs there.
4. Add `<slug>-sealedsecret.yaml` to `resources:` in that directory's
   `kustomization.yaml` — keep the list alphabetical. Miss this and the sealed
   file is inert: `kubectl apply -k` only applies what `resources:` lists, so
   the workload comes up in `CreateContainerConfigError` with no obvious cause.
5. Reference it from the workload with `valueFrom.secretKeyRef` (or
   `envFrom.secretRef`, or a volume) — never a literal `value:`.
6. `make -C server seal-<slug>`, apply, commit the sealed file.
7. `make -C server check-cleartext` before committing, and `kubectl kustomize .`
   to confirm the SealedSecret actually renders.

Do not add cleartext `Secret` manifests to `apps/` or `monitoring/` again. That
is what `check-cleartext` guards, and it is worth wiring into a pre-commit hook
if this repo ever grows one.

