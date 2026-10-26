# Every tool the README needs to deploy the server from scratch, at the
# versions it was deployed with:
#
#   docker build -t home-lab-tools .
#   make shell           # runs it with this repo and ~/.kube mounted
#
# Pins: talosctl follows talosVersion and kubectl follows kubernetesVersion in
# talos/talconfig.yaml; kubeseal must be no newer than the sealed-secrets
# controller (chart 2.20.0 = controller 0.40.0, server/helmfile.yaml).
FROM debian:trixie-slim

ARG TALOSCTL_VERSION=1.14.2
ARG TALHELPER_VERSION=3.1.17
ARG KUBECTL_VERSION=1.36.3
ARG HELM_VERSION=4.3.1
ARG HELM_DIFF_VERSION=3.15.14
ARG HELMFILE_VERSION=1.8.0
ARG KUBESEAL_VERSION=0.40.0
ARG KUBECONFORM_VERSION=0.8.0
ARG YQ_VERSION=4.54.1
# Set by buildx: amd64 or arm64. Every tool below ships both.
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash-completion ca-certificates curl dnsutils git jq less make \
      python3 python3-yaml \
 && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /tmp/dl

# Plain binaries.
RUN set -eux; a="${TARGETARCH}"; \
    get() { curl -fsSL --retry 3 -o "/usr/local/bin/$1" "$2"; chmod 0755 "/usr/local/bin/$1"; }; \
    get talosctl "https://github.com/siderolabs/talos/releases/download/v${TALOSCTL_VERSION}/talosctl-linux-${a}"; \
    get kubectl  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${a}/kubectl"; \
    get yq       "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${a}"

# Tarballs: fetch, then copy the named binaries out.
RUN set -eux; a="${TARGETARCH}"; \
    untar() { url="$1"; shift; rm -rf x && mkdir x; curl -fsSL --retry 3 "$url" | tar -xz -C x; \
              for b in "$@"; do install -m 0755 "$(find x -type f -name "$b" | head -1)" /usr/local/bin/; done; }; \
    untar "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${a}.tar.gz" helm; \
    untar "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${a}.tar.gz" helmfile; \
    untar "https://github.com/budimanjojo/talhelper/releases/download/v${TALHELPER_VERSION}/talhelper_linux_${a}.tar.gz" talhelper; \
    untar "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-${a}.tar.gz" kubeseal; \
    untar "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-${a}.tar.gz" kubeconform; \
    rm -rf x

# `helmfile apply` diffs through helm-diff. Helm 4 verifies plugin signatures
# by default and helm-diff's tarball is not signed.
RUN helm plugin install https://github.com/databus23/helm-diff --version "v${HELM_DIFF_VERSION}" --verify=false

RUN set -eux; \
    for t in talosctl kubectl helm helmfile talhelper; do "$t" completion bash > "/usr/share/bash-completion/completions/$t"; done; \
    echo 'source /usr/share/bash-completion/bash_completion; alias k=kubectl; complete -o default -F __start_kubectl k' >> /root/.bashrc

# The repo is bind-mounted here (make shell). TALOSCONFIG points at the
# talhelper output inside it; KUBECONFIG comes from the host.
WORKDIR /work
ENV TALOSCONFIG=/work/talos/clusterconfig/talosconfig \
    KUBECONFIG=/root/.kube/config
RUN git config --global --add safe.directory /work

CMD ["bash"]
