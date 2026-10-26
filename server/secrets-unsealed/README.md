# `secrets-unsealed/` — local-only inputs to `kubeseal`

Everything in this directory except this README and the `*.yaml.example`
templates is **gitignored** (see the
repo-root `.gitignore`). These are the *cleartext* Kubernetes `Secret`
manifests that `kubeseal` encrypts into the committed
`*-sealedsecret.yaml` files under `../apps/` and `../monitoring/`.

They are kept — rather than deleted — because sealing is not reversible without
the controller's private key. Losing these files means recovering every value
from the running cluster (or the service it belongs to) before you can reseal.

## Rules

- **Never `git add -f` anything here.** The whole point of SealedSecrets is that
  cleartext stays off the server.
- **Never `kubectl apply` from this directory.** Applying works (they are valid
  `Secret` manifests) but it bypasses the sealed copy, so the cluster and the
  repo silently drift. Seal, then apply the sealed file.
- One file per `Secret` object, named `<slug>.yaml`, where `<slug>` is the key
  used by the `make seal-<slug>` target in `../Makefile`.
- `metadata.name` and `metadata.namespace` must match the `Secret` the workload
  expects. SealedSecrets are sealed *strictly* by default: a sealed blob for
  `default/sonarr` will not decrypt as `default/sonarr-2` or `other-ns/sonarr`.
- Prefer `stringData:` for new values — it is readable and cannot accumulate a
  stray trailing newline the way hand-rolled `data:` base64 does. Existing
  entries that were migrated as `data:` are kept byte-identical on purpose.

## Workflow

```sh
$EDITOR server/secrets-unsealed/sonarr.yaml   # change the value
make -C server seal-sonarr                    # rewrite the sealed file
kubectl apply -f server/apps/sonarr/          # push it to the cluster
git add server/apps/sonarr/sonarr-sealedsecret.yaml && git commit
```

Full runbook, including how to back up the controller's sealing key:
[`../SECRETS.md`](../SECRETS.md).

The `*.yaml.example` files here are the cleartext templates, one per slug.
`scripts/init-secrets.sh` copies each to `<slug>.yaml` (never overwriting one
that exists) and fills every `@RANDOM…@` placeholder; the `CHANGE_ME` values
come from outside the cluster (Cloudflare, BotFather, the apps' own UIs).
