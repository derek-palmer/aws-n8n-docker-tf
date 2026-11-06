#!/usr/bin/env bash
# =============================================================================
# teardown.sh — Completely remove all AWS resources for an n8n environment
#
# Removes the bootstrap-managed resources for the given environment:
#   1. SSM params under /n8n/<env>/
#   2. That env's Terraform state in the S3 state bucket
#   3. Shared resources (ECR repo, state bucket, lock table) — only once no
#      other environment's state remains in the bucket.
#
# Terraform-managed infra is destroyed first by `make teardown` (tf-destroy).
# Run via make; running this script alone leaves that infra orphaned.
#
# ⚠️  THIS IS IRREVERSIBLE. All data will be lost.
#
# Usage:
#   make teardown env=<env>
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)
      [[ $# -ge 2 ]] || error "--env requires a value."
      ENV="$2"; shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -n "${ENV}" ]] || error "Missing required --env argument."

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
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"
STATE_BUCKET="n8n-tf-state-${AWS_ACCOUNT_ID}"
LOCK_TABLE="n8n-tf-locks"
ECR_REPO_NAME="n8n" # Must match bootstrap.sh

info "AWS account: ${AWS_ACCOUNT_ID} | Region: ${AWS_REGION} | Env: ${ENV}"
echo ""

# =============================================================================
# Step 1: SSM Parameters
# =============================================================================
info "Step 1/3 — Deleting SSM parameters at /n8n/${ENV}/..."

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
# Step 2: This env's Terraform state
# The bucket is shared by all envs, so only envs/<env>/ is removed here.
# =============================================================================
info "Step 2/3 — Deleting Terraform state for '${ENV}' from ${STATE_BUCKET}..."

remaining=None
if aws s3api head-bucket --bucket "${STATE_BUCKET}" &>/dev/null; then
  # Bulk delete-objects; the CLI query emits the payload directly. 500 per
  # list call keeps versions + delete markers under the 1000-key limit.
  while batch=$(aws s3api list-object-versions --bucket "${STATE_BUCKET}" --prefix "envs/${ENV}/" --max-items 500 \
      --query '{Objects: [Versions[], DeleteMarkers[]][].{Key:Key,VersionId:VersionId}, Quiet: `true`}' --output json) \
      && [[ "${batch}" != *'"Objects": []'* ]]; do
    aws s3api delete-objects --bucket "${STATE_BUCKET}" --delete "${batch}" >/dev/null
  done
  success "Deleted state for '${ENV}'."

  remaining=$(aws s3api list-object-versions --bucket "${STATE_BUCKET}" --max-keys 1 --no-paginate \
    --query 'Versions[0].Key || DeleteMarkers[0].Key' --output text)
else
  warn "S3 bucket '${STATE_BUCKET}' not found — skipping."
fi

# =============================================================================
# Step 3: Shared resources (ECR, state bucket, lock table)
# Only removed when no other environment's state remains.
# =============================================================================
info "Step 3/3 — Shared resources..."

if [[ "${remaining}" != None ]]; then
  warn "Bucket still holds other state (e.g. ${remaining}) — skipping ECR, state bucket, and lock table."
else
  if aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    aws ecr delete-repository --repository-name "${ECR_REPO_NAME}" --force --region "${AWS_REGION}" >/dev/null
    success "Deleted ECR repository: ${ECR_REPO_NAME}"
  else
    warn "ECR repository '${ECR_REPO_NAME}' not found — skipping."
  fi

  if aws s3api head-bucket --bucket "${STATE_BUCKET}" &>/dev/null; then
    aws s3 rb "s3://${STATE_BUCKET}" >/dev/null
    success "Deleted S3 state bucket: ${STATE_BUCKET}"
  fi

  if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" &>/dev/null; then
    aws dynamodb delete-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" >/dev/null
    success "Deleted DynamoDB lock table: ${LOCK_TABLE}"
  else
    warn "DynamoDB table '${LOCK_TABLE}' not found — skipping."
  fi
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
