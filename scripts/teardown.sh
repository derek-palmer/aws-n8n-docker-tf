#!/usr/bin/env bash
# =============================================================================
# teardown.sh — Completely remove all AWS resources for an n8n environment
#
# This script destroys EVERYTHING for the given environment:
#   1. All Terraform-managed infrastructure (EC2, ALB, VPC, CI/CD, etc.)
#   2. All bootstrap-managed resources (S3 state bucket, DynamoDB, ECR, SSM params)
#
# ⚠️  THIS IS IRREVERSIBLE. All data will be lost.
#
# Usage:
#   AWS_PROFILE=<profile> bash scripts/teardown.sh --env test
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV="test"

while [[ $# -gt 0 ]]; do
  case $1 in
    --env) ENV="$2"; shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

echo ""
echo -e "${RED}============================================================${NC}"
echo -e "${RED}  ⚠️  TEARDOWN — environment: ${YELLOW}${ENV}${NC}"
echo -e "${RED}  This will permanently destroy ALL resources and data.${NC}"
echo -e "${RED}============================================================${NC}"
echo ""

# Hard confirmation — must type the env name exactly
read -rp "  Type the environment name '${ENV}' to confirm: " CONFIRM
[[ "${CONFIRM}" != "${ENV}" ]] && error "Confirmation did not match. Aborting."

# Second gate — explicit yes required
read -rp "  Are you absolutely sure? This cannot be undone. [y/N]: " FINAL
[[ "${FINAL}" != "y" && "${FINAL}" != "Y" ]] && error "Aborted."

echo ""

# Verify AWS access
resolve_aws_profile
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
STATE_BUCKET="n8n-tf-state-${AWS_ACCOUNT_ID}"
LOCK_TABLE="n8n-tf-locks"

info "AWS account: ${AWS_ACCOUNT_ID} | Region: ${AWS_REGION} | Env: ${ENV}"
echo ""

# =============================================================================
# Step 1: Terraform destroy (managed infrastructure)
# =============================================================================
info "Step 1/4 — Destroying Terraform-managed infrastructure..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_ENV_DIR="${REPO_ROOT}/infra/terraform/envs/${ENV}"

if [[ ! -f "${TF_ENV_DIR}/terraform.tfstate" ]] && ! aws s3 ls "s3://${STATE_BUCKET}/envs/${ENV}/terraform.tfstate" &>/dev/null; then
  warn "No Terraform state found for '${ENV}' — skipping tf destroy."
else
  docker run --rm -i \
    -v "${REPO_ROOT}:/workspace" \
    -w "/workspace/infra/terraform/envs/${ENV}" \
    -v "${HOME}/.aws:/root/.aws:ro" \
    -e AWS_PROFILE \
    -e AWS_REGION \
    -e AWS_DEFAULT_REGION \
    hashicorp/terraform:latest destroy -auto-approve
  success "Terraform infrastructure destroyed."
fi

# =============================================================================
# Step 2: SSM Parameters
# =============================================================================
info "Step 2/4 — Deleting SSM parameters at /n8n/${ENV}/..."

PARAMS=$(aws ssm get-parameters-by-path \
  --path "/n8n/${ENV}" \
  --recursive \
  --query "Parameters[*].Name" \
  --output text \
  --region "${AWS_REGION}" 2>/dev/null || true)

if [[ -n "${PARAMS}" ]]; then
  # delete-parameters accepts up to 10 at a time
  echo "${PARAMS}" | tr '\t' '\n' | xargs -n10 \
    aws ssm delete-parameters --region "${AWS_REGION}" --names >/dev/null
  success "SSM parameters deleted."
else
  warn "No SSM parameters found at /n8n/${ENV}/ — skipping."
fi

# =============================================================================
# Step 3: ECR Repository
# =============================================================================
info "Step 3/4 — Deleting ECR repository 'n8n'..."

if aws ecr describe-repositories --repository-names "n8n" --region "${AWS_REGION}" &>/dev/null; then
  aws ecr delete-repository \
    --repository-name "n8n" \
    --force \
    --region "${AWS_REGION}" >/dev/null
  success "ECR repository deleted."
else
  warn "ECR repository 'n8n' not found — skipping."
fi

# =============================================================================
# Step 4: Terraform state backend (S3 + DynamoDB)
# Note: Do this LAST — we need the state bucket until tf destroy is done.
# =============================================================================
info "Step 4/4 — Deleting Terraform state backend (S3 + DynamoDB)..."

if aws s3api head-bucket --bucket "${STATE_BUCKET}" &>/dev/null; then
  # Empty and delete the bucket (force-removes all versioned objects)
  aws s3 rb "s3://${STATE_BUCKET}" --force >/dev/null
  success "Deleted S3 state bucket: ${STATE_BUCKET}"
else
  warn "S3 bucket '${STATE_BUCKET}' not found — skipping."
fi

if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" &>/dev/null; then
  aws dynamodb delete-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" >/dev/null
  success "Deleted DynamoDB lock table: ${LOCK_TABLE}"
else
  warn "DynamoDB table '${LOCK_TABLE}' not found — skipping."
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Teardown complete for env: ${ENV}${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  To redeploy from scratch: make bootstrap env=${ENV}"
echo ""
