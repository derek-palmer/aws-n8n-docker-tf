#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/stop.sh <env>
# This script gracefully stops the running Docker compose stack
# It is executed by the ApplicationStop hook during AWS CodeDeploy

ENV="${ENV:-${1:-test}}"
APP_DIR="/opt/n8n-app"

echo "Stopping n8n in ${ENV} environment..."

if [[ -d "${APP_DIR}" ]]; then
  cd "${APP_DIR}"
  
  if [[ -f "docker-compose.yml" && -f "docker-compose.aws.yml" ]]; then
    echo "Running docker compose down..."
    # Always try to load the environment file so interpolations succeed, but ignore failures if it doesn't exist
    if [[ -f ".env.${ENV}" ]]; then
        docker compose -f docker-compose.yml -f docker-compose.aws.yml --env-file ".env.${ENV}" down || true
    else
        docker compose -f docker-compose.yml -f docker-compose.aws.yml down || true
    fi
    echo "Stack stopped gracefully."
  else
    echo "No compose files found. Stack may not be running. Skipping stop."
  fi
else
  echo "App directory ${APP_DIR} does not exist. Skipping stop."
fi

exit 0
