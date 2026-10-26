# Run inside the tools image (`make shell`), or anywhere the same tools are on
# PATH. README.md is the from-scratch runbook; these are its steps.

NODE  ?= 192.168.1.2
IMAGE ?= home-lab-tools

TALHELPER := cd talos && talhelper
export TALOSCONFIG ?= $(CURDIR)/talos/clusterconfig/talosconfig

.PHONY: help image shell \
	talos-gen talos-image-url talos-install talos-bootstrap talos-kubeconfig \
	talos-apply talos-upgrade talos-upgrade-k8s \
	secrets-init seal cluster-up helm-deps server-validate server-helm

help:
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t 22

## --- tools image ------------------------------------------------------------

image: ## build the tools image from Dockerfile
	docker build -t $(IMAGE) .

shell: image ## a shell in the tools image: repo at /work, ~/.kube mounted
	mkdir -p $(HOME)/.kube
	docker run --rm -it \
		-v $(CURDIR):/work \
		-v $(HOME)/.kube:/root/.kube \
		-e NODE=$(NODE) \
		$(IMAGE)

## --- Talos ------------------------------------------------------------------

talos-gen: ## render talos/clusterconfig/ (git-ignored: it holds the PKI)
	$(TALHELPER) genconfig

talos-image-url: ## Image Factory URLs: ISO for the USB stick, installer for upgrades
	$(TALHELPER) genurl image
	$(TALHELPER) genurl installer

talos-install: talos-gen ## first apply to a node in maintenance mode (wipes the system disk)
	$(TALHELPER) gencommand apply --extra-flags --insecure | sh

talos-bootstrap: ## bootstrap etcd, exactly once per cluster
	talosctl -n $(NODE) -e $(NODE) bootstrap

talos-kubeconfig: ## merge the admin kubeconfig as context `home-lab` (helmfile.yaml pins it)
	talosctl -n $(NODE) -e $(NODE) kubeconfig --force-context-name home-lab

talos-apply: talos-gen ## push changed machine config (most changes need no reboot)
	$(TALHELPER) gencommand apply | sh

talos-upgrade: talos-gen ## new Talos version / extensions / kernel args: reboots
	$(TALHELPER) gencommand upgrade | sh

talos-upgrade-k8s: talos-gen ## bump Kubernetes to kubernetesVersion
	$(TALHELPER) gencommand upgrade-k8s | sh

## --- Kubernetes -------------------------------------------------------------

secrets-init: ## write server/secrets-unsealed/*.yaml from the templates (never overwrites)
	./scripts/init-secrets.sh

seal: ## seal every cleartext secret against the cluster's controller
	$(MAKE) -C server seal

# The order matters on an empty cluster: no CNI means no pods at all, the
# SealedSecret and Traefik CRDs must exist before the overlay that uses them,
# and the charts read Secrets the overlay creates. `sync`, not `apply`:
# helm-diff cannot map CRD-backed objects before their CRDs exist.
cluster-up: ## deploy everything onto a freshly bootstrapped node (README, шаг 6)
	cd server && helmfile -l name=cilium sync
	kubectl wait --for=condition=Ready node --all --timeout=10m
	kubectl apply -k server/local-path
	cd server && helmfile -l name=sealed-secrets sync
	kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=5m
	$(MAKE) -C server seal
	kubectl apply -f server/helm/traefik/cloudflare-sealedsecret.yaml
	cd server && helmfile -l name=traefik sync
	kubectl apply -k server
	cd server && helmfile -l name=homarr sync

helm-deps: ## re-resolve the chart pins into server/helmfile.lock
	cd server && helmfile deps

server-validate: ## kubeconform (strict) over server/apps + server/monitoring, offline
	./server/validate.sh manifests

server-helm: ## helmfile template + kubeconform the rendered charts (needs chart repos)
	./server/validate.sh helm
