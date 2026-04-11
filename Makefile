SHELL := /bin/bash
.PHONY: up-local up-local-version down-local setup-local tf-init tf-plan tf-apply tf-destroy tf-fmt tf-validate bootstrap setup-ssm teardown help

# Default environment if not specified via `make <command> env=<env>`
env ?= local

# Containerized Terraform — no local Terraform install needed.
# AWS SSO credentials are picked up via AWS_PROFILE + the ~/.aws mount (includes sso/cache/).
# Usage: make tf-plan env=prod   (after running your awslogin alias)
TF_CMD = docker run --rm -i \
	-v "$(PWD):/workspace" \
	-w "/workspace/infra/terraform/envs/$(env)" \
	-v "$$HOME/.aws:/root/.aws" \
	-e AWS_PROFILE \
	-e AWS_REGION \
	-e AWS_DEFAULT_REGION \
	hashicorp/terraform:1.7

# Credentials are resolved on the host (handles SSO) then injected into
# the repo's AWS CLI helper image, which includes jq.
SCRIPT_CMD = bash scripts/lib/aws_docker_run.sh

# Plain Docker runner — no AWS credentials needed (used for local-only scripts).
# --user ensures files written to mounted volumes are owned by the host user, not root.
LOCAL_SCRIPT_CMD = docker run --rm -it \
	--entrypoint bash \
	--user "$(shell id -u):$(shell id -g)" \
	-v "$(PWD):/workspace" \
	-w "/workspace" \
	amazon/aws-cli:2.15.0

help:
	@echo "Prerequisites: aws sso login (credentials are auto-detected)"
	@echo ""
	@echo "Local Development:"
	@echo "  make setup-local           One-shot: setup SSM params + start local stack"
	@echo "  make up-local              Fetch SSM params and start local docker-compose stack"
	@echo "  make up-local-version      Run local n8n with N8N_UPSTREAM_REF=<image> for upgrade checks"
	@echo "  make down-local            Stop local docker-compose stack"
	@echo ""
	@echo "AWS Environment Setup (active path is prod):"
	@echo "  make bootstrap env=prod    Full setup (state bucket, ECR, SSM params, tfvars)"
	@echo "  make setup-ssm env=prod    Create/update SSM Parameter Store entries only"
	@echo ""
	@echo "Terraform Infrastructure:"
	@echo "  make tf-init env=<env>     Initialize terraform workspace"
	@echo "  make tf-fmt env=<env>      Format HCL files"
	@echo "  make tf-validate env=<env> Validate terraform configuration"
	@echo "  make tf-plan env=<env>     Plan terraform changes"
	@echo "  make tf-apply env=<env>    Apply terraform changes (ARGS=-auto-approve to skip prompt)"
	@echo "  make tf-destroy env=<env>  Destroy only Terraform-managed infra"
	@echo ""
	@echo "⚠️  Danger Zone:"
	@echo "  make teardown env=<env>    Destroy ALL resources including state, ECR, and SSM (irreversible)"

# --- Local development ---
# No AWS credentials required for local setup.
# Generates .env.local directly; test/prod still use SSM.

setup-local:
	$(LOCAL_SCRIPT_CMD) scripts/setup_local_env.sh

up-local:
	docker compose -f docker-compose.yml -f docker-compose.local.yml --env-file .env.local up -d --build --wait
	@echo ""
	@echo "  ✅ n8n is running → http://localhost:5678"
	@echo ""

up-local-version:
	@if [ -z "$(N8N_UPSTREAM_REF)" ]; then echo "Set N8N_UPSTREAM_REF=<image> to test a candidate n8n version."; exit 1; fi
	N8N_UPSTREAM_REF="$(N8N_UPSTREAM_REF)" docker compose -f docker-compose.yml -f docker-compose.local.yml --env-file .env.local pull n8n
	N8N_UPSTREAM_REF="$(N8N_UPSTREAM_REF)" docker compose -f docker-compose.yml -f docker-compose.local.yml --env-file .env.local up -d --wait
	@echo ""
	@echo "  ✅ Candidate n8n is running → http://localhost:5678"
	@echo "  ℹ️  Image under test: $(N8N_UPSTREAM_REF)"
	@echo ""

down-local:
	docker compose -f docker-compose.yml -f docker-compose.local.yml down

# --- AWS environment setup ---

bootstrap:
	$(SCRIPT_CMD) scripts/bootstrap.sh --env $(env)

setup-ssm:
	$(SCRIPT_CMD) scripts/setup_ssm_params.sh --env $(env)

teardown:
	@echo ""
	@echo "⚠️  WARNING: make teardown will permanently destroy ALL resources for env=$(env)"
	@echo "⚠️  This includes EC2, VPC, SSM params, ECR, and the Terraform state bucket."
	@echo ""
	$(SCRIPT_CMD) scripts/teardown.sh --env $(env)

# --- Terraform ---

tf-init:
	$(TF_CMD) init

tf-fmt:
	$(TF_CMD) fmt -recursive /workspace

tf-validate: tf-init
	$(TF_CMD) validate

tf-plan: tf-validate
	$(TF_CMD) plan

tf-apply: tf-validate
	$(TF_CMD) apply $(ARGS)

tf-destroy: tf-validate
	$(TF_CMD) destroy $(ARGS)
