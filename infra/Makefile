# Manual low-privilege image build helpers and emergency runtime plan/apply.
# Normal production deploys use the bootstrap-owned inline Cloud Build triggers.
PROJECT ?= hop-mesh
REGION  ?= us-central1
REPO    ?= $(REGION)-docker.pkg.dev/$(PROJECT)/hop
TAG     ?= $(shell git rev-parse HEAD)
IMAGE   ?= $(REPO)/hop-relayd:$(TAG)
ROOT    := $(shell git rev-parse --show-toplevel)
TF      ?= tofu

.PHONY: auth image push plan apply seed-identity

auth:
	gcloud auth configure-docker $(REGION)-docker.pkg.dev --quiet

# Build for linux/amd64 (Cloud Run) regardless of host arch.
image:
	docker build --platform linux/amd64 \
	  -f $(ROOT)/services/hop-relayd/Dockerfile \
	  -t $(IMAGE) $(ROOT)

push: image
	docker push $(IMAGE)
	@echo "pushed $(IMAGE)"

# Seed the shared relay identity ONCE (32 random bytes). Idempotency is on you:
# running again rotates the relay's address.
seed-identity:
	head -c 32 /dev/urandom \
	  | gcloud secrets versions add hop-relay-identity --project $(PROJECT) --data-file=-

plan:
	@test -n "$(TFVARS)" || { echo "set TFVARS to a verified provenance tfvars file" >&2; exit 1; }
	$(TF) plan -var-file="$(TFVARS)"

apply:
	@test -n "$(TFVARS)" || { echo "set TFVARS to a verified provenance tfvars file" >&2; exit 1; }
	$(TF) apply -var-file="$(TFVARS)"
