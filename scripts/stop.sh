#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/stop.sh <env>
# This script gracefully stops the running Docker compose stack
# It is executed by the ApplicationStop hook during AWS CodeDeploy

if [[ -n "${DEPLOYMENT_GROUP_NAME:-}" ]]; then
  ENV="${DEPLOYMENT_GROUP_NAME#n8n-}"
  ENV="${ENV%-group}"
elif [[ -n "${ENV:-}" ]]; then
  ENV="${ENV}"
elif [[ $# -ge 1 ]]; then
  ENV="$1"
else
  echo "Usage: ./scripts/stop.sh <env>" >&2
  exit 1
fi
APP_DIR="/opt/n8n-app"

echo "Stopping n8n in ${ENV} environment..."

if [[ -d "${APP_DIR}" ]]; then
  cd "${APP_DIR}"
  
  if [[ -f "docker-compose.yml" && -f "docker-compose.aws.yml" ]]; then
    echo "Running docker compose down..."
    # Load whichever env files exist so interpolations succeed; ignore failures.
    COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.aws.yml)
    [[ -f ".env.${ENV}" ]] && COMPOSE+=(--env-file ".env.${ENV}")
    [[ -f "build.env" ]] && COMPOSE+=(--env-file build.env)
    "${COMPOSE[@]}" down || true
    echo "Stack stopped gracefully."
  else
    echo "No compose files found. Stack may not be running. Skipping stop."
  fi
else
  echo "App directory ${APP_DIR} does not exist. Skipping stop."
fi

exit 0
