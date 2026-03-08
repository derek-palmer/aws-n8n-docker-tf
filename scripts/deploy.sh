#!/usr/bin/env bash
set -e

# Usage: ./scripts/deploy.sh <env>
# This script is meant to be run automatically by AWS CodeDeploy or manually via SSM Run Command on the EC2 instance.

ENV=${1:-test}
APP_DIR="/opt/n8n-app"

echo "Starting Deployment for n8n in ${ENV} environment..."

# 1. Ensure application directory exists
mkdir -p "${APP_DIR}"
cd "${APP_DIR}"

# 2. Pull down the latest infrastructure configurations
# In a real environment, CodeDeploy handles pulling the latest git repo to this folder.
# Here we simulate fetching the latest configurations.

# 3. Fetch latest environment variables from SSM
echo "Fetching latest SSM configuration secrets..."
bash ./scripts/fetch_ssm_env.sh "${ENV}"

# 4. Pull the latest docker images
# Note: For ECR you'd need `aws ecr get-login-password | docker login...`
echo "Pulling latest docker images..."
docker compose -f docker-compose.yml -f docker-compose.aws.yml --env-file ".env.${ENV}" pull

# 5. Restart the docker stack
echo "Bringing up the stack..."
docker compose -f docker-compose.yml -f docker-compose.aws.yml --env-file ".env.${ENV}" up -d --remove-orphans

echo "Deployment complete! ✅"
