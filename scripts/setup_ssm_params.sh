#!/usr/bin/env bash
# =============================================================================
# setup_ssm_params.sh — Create or update SSM Parameter Store entries for n8n
#
# Safe to re-run — skips params that already exist unless --overwrite is passed.
#
# Usage:
#   bash scripts/setup_ssm_params.sh --env test
#   bash scripts/setup_ssm_params.sh --env prod --overwrite
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Defaults ---
ENV="test"
OVERWRITE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)
      if [[ -z "${2:-}" ]]; then
        error "--env requires a non-empty value"
      fi
      if ! [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]]; then
        error "Invalid environment name: '$2'. Only alphanumeric characters, dots, underscores, and dashes are allowed."
      fi
      ENV="$2"
      shift 2
      ;;
    --overwrite) OVERWRITE=true; shift ;;
    *) error "Unknown argument: $1" ;;
  esac
done

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  n8n SSM Parameter Setup — environment: ${YELLOW}${ENV}${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# Verify AWS access
resolve_aws_profile
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"

info "AWS account: ${AWS_ACCOUNT_ID} | Region: ${AWS_REGION} | Env: ${ENV}"
echo ""

# --- Helper: put a single parameter ---
# Writes a parameter to AWS Systems Manager Parameter Store.
# Parameters:
#   $1: The SSM parameter path (e.g., /n8n/test/app/host)
#   $2: The value to store
#   $3: The parameter type (default: SecureString)
put_param() {
  local name="$1" value="$2" type="${3:-SecureString}"

  if aws ssm get-parameter --name "${name}" --region "${AWS_REGION}" &>/dev/null; then
    if [[ "${OVERWRITE}" == true ]]; then
      aws ssm put-parameter \
        --name "${name}" --value "${value}" --type "${type}" \
        --overwrite --region "${AWS_REGION}" >/dev/null
      success "Updated:  ${name}"
    else
      warn "Exists (skipped): ${name}  — re-run with --overwrite to update"
    fi
  else
    aws ssm put-parameter \
      --name "${name}" --value "${value}" --type "${type}" \
      --region "${AWS_REGION}" >/dev/null
    success "Created:  ${name}"
  fi
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  value=${value//$'\f'/\\f}
  value=${value//$'\b'/\\b}
  printf '%s' "${value}"
}

# --- Prompt for values ---
echo -e "${CYAN}--- Application Config ---${NC}"
echo -e "${YELLOW}(Press Enter to accept the default shown)${NC}"
echo ""

# For local env, sensible defaults are localhost/http — no domain needed
if [[ "${ENV}" == "local" ]]; then
  DEFAULT_HOST="localhost"
  DEFAULT_PROTOCOL="http"
else
  DEFAULT_HOST=""
  DEFAULT_PROTOCOL="https"
fi

if [[ -z "${DEFAULT_HOST}" ]]; then
  prompt "n8n host (e.g. n8n-test.example.com):"
  while true; do
    read -re -p "  > " N8N_HOST
    if [[ -z "${N8N_HOST}" ]]; then
      warn "Host cannot be blank for non-local env."
    else
      break
    fi
  done
else
  read -re -i "${DEFAULT_HOST}" -p "  Host:     " N8N_HOST
fi

read -re -i "${DEFAULT_PROTOCOL}" -p "  Protocol: " N8N_PROTOCOL
read -re -i "5678"               -p "  Port:     " N8N_PORT

prompt "n8n encryption key (leave blank to auto-generate):"
read -rsp "  > " N8N_ENCRYPTION_KEY
echo ""
[[ -z "${N8N_ENCRYPTION_KEY}" ]] && N8N_ENCRYPTION_KEY=$(od -vN 32 -A n -t x1 /dev/urandom | tr -d ' \n') && info "Auto-generated encryption key."

echo ""
echo -e "${CYAN}--- Database Config ---${NC}"
read -re -i "n8n" -p "  Postgres username:      " PG_USER
read -re -i "n8n" -p "  Postgres database name: " PG_DB

prompt "Postgres password (leave blank to auto-generate):"
read -rsp "  > " PG_PASSWORD
echo ""
[[ -z "${PG_PASSWORD}" ]] && PG_PASSWORD=$(od -vN 16 -A n -t x1 /dev/urandom | tr -d ' \n') && info "Auto-generated Postgres password."

echo ""
echo -e "${CYAN}--- External Services ---${NC}"
echo -e "${YELLOW}(Optional - helps avoid pull rate limits during CodeBuild runs)${NC}"
echo ""

prompt "Docker Hub Username (e.g. your-docker-id):"
read -rp "  > " DOCKERHUB_USERNAME

prompt "Docker Hub Access Token (Create one at https://app.docker.com/settings/personal-access-tokens):"
read -rsp "  > " DOCKERHUB_TOKEN
echo ""

# Format as JSON for a single SSM parameter
DOCKERHUB_CREDENTIALS="{}"
if [[ -n "${DOCKERHUB_USERNAME}" && -n "${DOCKERHUB_TOKEN}" ]]; then
  DOCKERHUB_CREDENTIALS=$(printf '{"username":"%s","token":"%s"}' \
    "$(json_escape "${DOCKERHUB_USERNAME}")" \
    "$(json_escape "${DOCKERHUB_TOKEN}")")
fi

# --- Push to SSM ---
echo ""
info "Writing parameters to /n8n/${ENV}/..."
echo ""

put_param "/n8n/${ENV}/N8N_ENCRYPTION_KEY" "${N8N_ENCRYPTION_KEY}" "SecureString"
put_param "/n8n/${ENV}/N8N_HOST"           "${N8N_HOST}"           "String"
put_param "/n8n/${ENV}/N8N_PROTOCOL"       "${N8N_PROTOCOL}"       "String"
put_param "/n8n/${ENV}/N8N_PORT"           "${N8N_PORT}"           "String"
put_param "/n8n/${ENV}/POSTGRES_USER"      "${PG_USER}"            "SecureString"
put_param "/n8n/${ENV}/POSTGRES_PASSWORD"  "${PG_PASSWORD}"        "SecureString"
put_param "/n8n/${ENV}/POSTGRES_DB"        "${PG_DB}"              "String"

if [[ "${DOCKERHUB_CREDENTIALS}" != "{}" ]]; then
  put_param "/n8n/${ENV}/DOCKERHUB_CREDENTIALS" "${DOCKERHUB_CREDENTIALS}" "SecureString"
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  SSM parameters configured for env: ${ENV}${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  To view them:"
echo -e "  ${CYAN}aws ssm get-parameters-by-path --path /n8n/${ENV} --with-decryption --query 'Parameters[*].{Name:Name,Value:Value}'${NC}"
echo ""

# Export for bootstrap.sh tfvars generation
export DOMAIN_NAME="${N8N_HOST#*.}"
export SUBDOMAIN="${N8N_HOST%%.*}"
