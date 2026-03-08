#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — One-time AWS environment setup for n8n-aws-infra-template
#
# Run this once after cloning the repo to set up all prerequisite AWS resources
# before running `make tf-apply`.
#
# Usage:
#   aws sso login --profile <profile>
#   AWS_PROFILE=<profile> bash scripts/bootstrap.sh
#
# Or with explicit env:
#   AWS_PROFILE=<profile> bash scripts/bootstrap.sh --env test
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Defaults ---
ENV="test"

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --env) ENV="$2"; shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  n8n AWS Infra Bootstrap — environment: ${YELLOW}${ENV}${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# =============================================================================
# 1. Check prerequisites
# =============================================================================
info "Checking prerequisites..."

command -v aws   &>/dev/null || error "aws CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
command -v docker &>/dev/null || error "docker not found. Install: https://docs.docker.com/engine/install/"

resolve_aws_profile
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

success "AWS account: ${AWS_ACCOUNT_ID}, region: ${AWS_REGION}"

# =============================================================================
# 2. Terraform state backend (S3 + DynamoDB)
# =============================================================================
STATE_BUCKET="n8n-tf-state-${AWS_ACCOUNT_ID}"
LOCK_TABLE="n8n-tf-locks"

info "Setting up Terraform state backend..."

# S3 bucket
if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  warn "S3 state bucket '${STATE_BUCKET}' already exists, skipping."
else
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${STATE_BUCKET}" --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${STATE_BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "${STATE_BUCKET}" \
    --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-encryption --bucket "${STATE_BUCKET}" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
  aws s3api put-public-access-block --bucket "${STATE_BUCKET}" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
  success "Created S3 state bucket: ${STATE_BUCKET}"
fi

# DynamoDB lock table
if aws dynamodb describe-table --table-name "${LOCK_TABLE}" 2>/dev/null | grep -q ACTIVE; then
  warn "DynamoDB lock table '${LOCK_TABLE}' already exists, skipping."
else
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}" >/dev/null
  success "Created DynamoDB lock table: ${LOCK_TABLE}"
fi

# Patch the backend config into the env main.tf
MAIN_TF="infra/terraform/envs/${ENV}/main.tf"
if grep -q "# backend" "${MAIN_TF}"; then
  info "Enabling S3 backend in ${MAIN_TF}..."
  # Use perl for portable in-place multi-line sed replacement
  perl -i -0pe \
    "s|# backend \"s3\" \{[^}]*\}|backend \"s3\" {\n    bucket         = \"${STATE_BUCKET}\"\n    key            = \"envs/${ENV}/terraform.tfstate\"\n    region         = \"${AWS_REGION}\"\n    dynamodb_table = \"${LOCK_TABLE}\"\n    encrypt        = true\n  }|" \
    "${MAIN_TF}"
  success "Backend configured in ${MAIN_TF}"
else
  warn "Backend block already uncommented in ${MAIN_TF}, skipping."
fi

# =============================================================================
# 3. ECR Repository
# =============================================================================
ECR_REPO_NAME="n8n"
info "Setting up ECR repository '${ECR_REPO_NAME}'..."

if aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" 2>/dev/null | grep -q repositoryName; then
  warn "ECR repository '${ECR_REPO_NAME}' already exists, skipping."
else
  aws ecr create-repository \
    --repository-name "${ECR_REPO_NAME}" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --region "${AWS_REGION}" >/dev/null
  success "Created ECR repository: ${ECR_REPO_NAME}"
fi

ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"
ECR_ARN="arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${ECR_REPO_NAME}"
success "ECR URL: ${ECR_URL}"

# =============================================================================
# 4. SSM Parameters
# =============================================================================
info "Running SSM parameter setup..."
echo ""

# Delegate to the dedicated script — it handles all prompting and pushing.
# We source it so we can pick up the DOMAIN_NAME / SUBDOMAIN variables it sets
# for use when writing terraform.tfvars below.
bash "$(dirname "$0")/setup_ssm_params.sh" --env "${ENV}"

# Re-prompt for domain values so we can write terraform.tfvars
# (setup_ssm_params.sh runs in a subshell so its vars aren't exported here)
echo ""
echo -e "${YELLOW}Re-enter domain values for terraform.tfvars:${NC}"
read -rp "  Root domain name (e.g. example.com): " DOMAIN_NAME
read -rp "  Subdomain for this env (e.g. n8n-test): " SUBDOMAIN

# =============================================================================
# 5. Update terraform.tfvars
# =============================================================================
TFVARS="infra/terraform/envs/${ENV}/terraform.tfvars"
info "Updating ${TFVARS} with computed values..."

# Prompt for GitHub details
echo ""
echo -e "${YELLOW}Enter your GitHub / CI details:${NC}"
read -rp "  GitHub repo (e.g. your-org/your-repo): " GITHUB_REPO
read -rp "  GitHub branch for this env [main]: " GITHUB_BRANCH
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

echo ""
warn "============================================================"
warn "  ACTION REQUIRED: Create a GitHub CodeStar Connection"
warn "  In the AWS Console (one-time per account):"
warn "  https://console.aws.amazon.com/codesuite/settings/connections"
warn "  Select GitHub, authorize, then paste the ARN below."
warn "============================================================"
read -rp "  CodeStar Connection ARN: " CODESTAR_ARN

# Write the tfvars
cat > "${TFVARS}" <<EOF
# ------------------------------------------------------------------------------
# ENVIRONMENT SPECIFIC CONFIGURATION (${ENV^^})
# Generated by scripts/bootstrap.sh — re-run to regenerate.
# ------------------------------------------------------------------------------

env        = "${ENV}"
aws_region = "${AWS_REGION}"
az         = "${AWS_REGION}a"

# DNS Configuration
domain_name = "${DOMAIN_NAME}"
subdomain   = "${SUBDOMAIN}"

# CI/CD Configuration 
github_repo             = "${GITHUB_REPO}"
github_branch           = "${GITHUB_BRANCH}"
codestar_connection_arn = "${CODESTAR_ARN}"
ecr_repository_url      = "${ECR_URL}"
ecr_repository_arn      = "${ECR_ARN}"
EOF

success "Updated ${TFVARS}"

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Bootstrap complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  Next steps:"
echo ""
echo -e "  1. ${CYAN}AWS_PROFILE=<profile> make tf-init env=${ENV}${NC}"
echo -e "  2. ${CYAN}AWS_PROFILE=<profile> make tf-plan env=${ENV}${NC}"
echo -e "  3. ${CYAN}AWS_PROFILE=<profile> make tf-apply env=${ENV} ARGS=-auto-approve${NC}"
echo ""
