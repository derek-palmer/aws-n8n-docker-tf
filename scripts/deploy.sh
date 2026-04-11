#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/deploy.sh <env>
# This script is meant to be run automatically by AWS CodeDeploy or manually via SSM Run Command on the EC2 instance.

# When run by CodeDeploy, DEPLOYMENT_GROUP_NAME will be e.g. "n8n-prod-group"
if [[ -n "${DEPLOYMENT_GROUP_NAME:-}" ]]; then
  # Extract 'prod' or 'test' from 'n8n-prod-group'
  ENV="${DEPLOYMENT_GROUP_NAME#n8n-}"  # strip "n8n-" prefix  → "prod-group"
  ENV="${ENV%-group}"                  # strip "-group" suffix → "prod"
else
  ENV=${1:-prod}
fi
APP_DIR="/opt/n8n-app"

# Setup trap for cleanup on failure
trap 'echo "Deployment failed! Performing cleanup..."; exit 1' ERR

echo "Starting Deployment for n8n in ${ENV} environment..."

# 1. Ensure application directory exists
mkdir -p "${APP_DIR}"
cd "${APP_DIR}"

# 1.5. Pre-flight checks
if [[ ! -f "docker-compose.yml" || ! -f "docker-compose.aws.yml" || ! -f "Caddyfile" ]]; then
  echo "Error: Required runtime files are missing in ${APP_DIR}."
  exit 1
fi

if [[ ! -f "scripts/fetch_ssm_env.sh" ]]; then
  echo "Error: SSM fetch script missing from ${APP_DIR}/scripts."
  exit 1
fi

if ! command -v aws >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
  echo "Error: Required commands (aws, docker) are not installed or in PATH."
  exit 1
fi

# 2. Pull down the latest infrastructure configurations
# In a real environment, CodeDeploy handles pulling the latest git repo to this folder.
# Here we simulate fetching the latest configurations.

# 3. Fetch latest environment variables from SSM
echo "Fetching latest SSM configuration secrets..."
bash ./scripts/fetch_ssm_env.sh "${ENV}"

echo "Validating docker compose configuration..."
docker compose -f docker-compose.yml -f docker-compose.aws.yml --env-file ".env.${ENV}" config >/dev/null

# 4. Pull the latest docker images from ECR
echo "Authenticating with ECR..."
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "Pulling latest docker images..."
docker compose -f docker-compose.yml -f docker-compose.aws.yml --env-file ".env.${ENV}" pull

# 5. Restart the docker stack
echo "Bringing up the stack..."
docker compose -f docker-compose.yml -f docker-compose.aws.yml --env-file ".env.${ENV}" up -d --remove-orphans

echo "Deployment complete! ✅"
