#!/usr/bin/env bash
# Offline k8s validation, shared by the Makefile and CI.
#
#   ./server/validate.sh [manifests|helm|all]
#
# Never talks to a cluster. No `kubectl --dry-run`: it would read a kubeconfig,
# and CI has none.
set -euo pipefail

cd "$(dirname "$0")/.."

export KUBECONFIG=/dev/null

# Keep in step with kubernetesVersion in talos/talconfig.yaml.
K8S_VERSION="${K8S_VERSION:-1.36.3}"

# The CRDs catalog covers Traefik Middleware and SealedSecret.
SCHEMAS=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

# No -ignore-missing-schemas: an unknown kind should fail. Kustomizations have
# no schema and aren't k8s objects, so they're skipped.
validate_manifests() {
  echo "==> kubeconform: server/apps + server/monitoring (k8s ${K8S_VERSION}, strict)"
  kubeconform \
    -kubernetes-version "$K8S_VERSION" \
    -strict \
    -summary \
    -ignore-filename-pattern 'kustomization\.yaml$' \
    -ignore-filename-pattern 'docker-compose\.ya?ml$' \
    "${SCHEMAS[@]}" \
    server/apps server/monitoring
}

# Rendered charts do use -ignore-missing-schemas: upstream charts ship CRDs
# that aren't in the catalog.
validate_helm() {
  echo "==> helmfile template: server/helmfile.yaml"

  # Private helm homes, so `repo add` doesn't touch ~/.config/helm.
  local helmhome="${XDG_CACHE_HOME:-$HOME/.cache}/home-lab-server-validate/helm"
  mkdir -p "$helmhome"
  export HELM_CACHE_HOME="$helmhome/cache"
  export HELM_CONFIG_HOME="$helmhome/config"
  export HELM_DATA_HOME="$helmhome/data"

  # kubeconform silently skips files without a .yaml extension.
  local tmpdir rendered
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  rendered="$tmpdir/rendered.yaml"
  helmfile -f server/helmfile.yaml template >"$rendered"

  echo "==> kubeconform: rendered charts (k8s ${K8S_VERSION}, strict, missing schemas ignored)"
  kubeconform \
    -kubernetes-version "$K8S_VERSION" \
    -strict \
    -summary \
    -ignore-missing-schemas \
    "${SCHEMAS[@]}" \
    "$rendered"
}

case "${1:-manifests}" in
manifests) validate_manifests ;;
helm) validate_helm ;;
all)
  validate_manifests
  validate_helm
  ;;
*)
  echo "usage: $0 [manifests|helm|all]" >&2
  exit 2
  ;;
esac
