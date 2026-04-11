#!/usr/bin/env bash
# =============================================================================
# teardown.sh — Completely remove all AWS resources for an n8n environment
#
# This script destroys EVERYTHING for the given environment:
#   1. All Terraform-managed infrastructure (EC2, Elastic IP, VPC, CI/CD, etc.)
#   2. All bootstrap-managed resources (S3 state bucket, DynamoDB, ECR, SSM params)
#
# ⚠️  THIS IS IRREVERSIBLE. All data will be lost.
#
# Usage:
#   bash scripts/teardown.sh --env test
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
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"
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
    hashicorp/terraform:latest init
    
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
info "Step 3/4 — Deleting ECR repository 'n8n-${ENV}'..."

if aws ecr describe-repositories --repository-names "n8n-${ENV}" --region "${AWS_REGION}" &>/dev/null; then
  aws ecr delete-repository \
    --repository-name "n8n-${ENV}" \
    --force \
    --region "${AWS_REGION}" >/dev/null
  success "ECR repository deleted."
else
  warn "ECR repository 'n8n-${ENV}' not found — skipping."
fi

# =============================================================================
# Step 4: Terraform state backend (S3 + DynamoDB)
# Note: Do this LAST — we need the state bucket until tf destroy is done.
# =============================================================================
info "Step 4/4 — Deleting Terraform state backend (S3 + DynamoDB)..."

if aws s3api head-bucket --bucket "${STATE_BUCKET}" &>/dev/null; then
  # Empty all objects and object versions via aws s3api to guarantee deletion.
  # Use bulk delete-objects (batches of 1000) instead of one delete-object per version.
  info "Clearing versioned objects from S3 bucket ${STATE_BUCKET}..."
  versions=$(aws s3api list-object-versions \
    --bucket "${STATE_BUCKET}" \
    --query 'concat(Versions[?VersionId!=`null`].[Key,VersionId], DeleteMarkers[?VersionId!=`null`].[Key,VersionId])' \
    --output text 2>/dev/null || true)
  if [[ -n "${versions}" ]]; then
    # Encode arbitrary strings as quoted JSON without assuming jq is installed.
    json_escape() {
      local input="$1"
      local output='"'
      local ch
      local code
      local i

      for ((i = 0; i < ${#input}; i++)); do
        ch="${input:i:1}"
        case "${ch}" in
          '\\') output+='\\\\' ;;
          '"') output+='\\"' ;;
          $'\n') output+='\n' ;;
          $'\r') output+='\r' ;;
          $'\t') output+='\t' ;;
          $'\b') output+='\b' ;;
          $'\f') output+='\f' ;;
          *)
            LC_CTYPE=C printf -v code '%d' "'${ch}"
            if ((code < 32)); then
              printf -v ch '\\u%04x' "${code}"
              output+="${ch}"
            else
              output+="${ch}"
            fi
            ;;
        esac
      done

      output+='"'
      printf '%s' "${output}"
    }
    batch_keys=()
    batch_ids=()
    while IFS=$'\t' read -r key version_id; do
      [[ -z "${key:-}" || -z "${version_id:-}" ]] && continue
      batch_keys+=("${key}")
      batch_ids+=("${version_id}")
      if [[ ${#batch_keys[@]} -ge 1000 ]]; then
        objects=""
        for i in "${!batch_keys[@]}"; do
          [[ -n "${objects}" ]] && objects+=","
          objects+="{\"Key\":$(json_escape "${batch_keys[$i]}"),\"VersionId\":$(json_escape "${batch_ids[$i]}")}"
        done
        aws s3api delete-objects --bucket "${STATE_BUCKET}" --delete "{\"Objects\":[${objects}],\"Quiet\":true}" >/dev/null
        batch_keys=()
        batch_ids=()
      fi
    done <<< "${versions}"
    # Delete any remaining batch (under 1000 items).
    if [[ ${#batch_keys[@]} -gt 0 ]]; then
      objects=""
      for i in "${!batch_keys[@]}"; do
        [[ -n "${objects}" ]] && objects+=","
        objects+="{\"Key\":$(json_escape "${batch_keys[$i]}"),\"VersionId\":$(json_escape "${batch_ids[$i]}")}"
      done
      aws s3api delete-objects --bucket "${STATE_BUCKET}" --delete "{\"Objects\":[${objects}],\"Quiet\":true}" >/dev/null
    fi
  fi
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
