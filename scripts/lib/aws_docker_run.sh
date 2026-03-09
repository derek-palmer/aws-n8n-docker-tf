#!/usr/bin/env bash
# =============================================================================
# scripts/lib/aws_docker_run.sh
#
# Resolves AWS credentials on the HOST then passes them into a Docker container.
# Handles profile selection and works with SSO, IAM keys, and assume-role.
# Can be customized per caller via:
#   AWS_DOCKER_IMAGE
#   AWS_DOCKER_WORKDIR
#   AWS_DOCKER_ENTRYPOINT
#   AWS_DOCKER_TTY=0
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- Source common utilities ---
source "${REPO_ROOT}/scripts/lib/common.sh"

# --- Determine which profile to use ---
resolve_aws_profile

# --- Resolve credentials on the host ---
if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
  : "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set with AWS_ACCESS_KEY_ID}"
else
  # Use --format env (with 'export') so eval both sets AND exports the vars,
  # making them available to `exec docker run -e AWS_ACCESS_KEY_ID ...`
  if ! creds=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env 2>/dev/null); then
    error "Could not resolve credentials for profile '${AWS_PROFILE}'.\nRun 'awslogin' in your terminal first, then retry:\n  aws sso login --profile ${AWS_PROFILE}"
  fi

  # shellcheck disable=SC2163
  eval "${creds}"
fi

if [[ -n "${AWS_PROFILE:-}" ]]; then
  PROFILE_REGION=$(aws configure get region --profile "${AWS_PROFILE}" 2>/dev/null || echo "us-east-1")
else
  PROFILE_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
fi

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-${PROFILE_REGION}}}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

DOCKER_IMAGE="${AWS_DOCKER_IMAGE:-amazon/aws-cli:2.15.0}"
DOCKER_WORKDIR="${AWS_DOCKER_WORKDIR:-/workspace}"
DOCKER_ENTRYPOINT="${AWS_DOCKER_ENTRYPOINT:-bash}"

docker_flags=(--rm -i)
if [[ "${AWS_DOCKER_TTY:-1}" != "0" ]]; then
  docker_flags+=(-t)
fi

if [[ "${DOCKER_ENTRYPOINT}" != "__none__" ]]; then
  docker_flags+=(--entrypoint "${DOCKER_ENTRYPOINT}")
fi

# --- Run the container with resolved credentials ---
exec docker run "${docker_flags[@]}" \
  -v "${REPO_ROOT}:/workspace" \
  -w "${DOCKER_WORKDIR}" \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN \
  -e AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" \
  -e AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION}" \
  -e AWS_REGION="${AWS_REGION}" \
  "${DOCKER_IMAGE}" \
  "$@"
