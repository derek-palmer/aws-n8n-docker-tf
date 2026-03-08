#!/usr/bin/env bash
# =============================================================================
# scripts/lib/aws_docker_run.sh
#
# Resolves AWS credentials on the HOST then passes them into a Docker container.
# Handles profile selection and works with SSO, IAM keys, and assume-role.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- Source common utilities ---
source "${REPO_ROOT}/scripts/lib/common.sh"

# --- Determine which profile to use ---
resolve_aws_profile

# --- Resolve credentials for this profile on the host ---
# Use --format env (with 'export') so eval both sets AND exports the vars,
# making them available to `exec docker run -e AWS_ACCESS_KEY_ID ...`
if ! creds=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env 2>/dev/null); then
  error "Could not resolve credentials for profile '${AWS_PROFILE}'.\nRun 'awslogin' in your terminal first, then retry:\n  aws sso login --profile ${AWS_PROFILE}"
fi

# Detect Profile Region specifically
PROFILE_REGION=$(aws configure get region --profile "${AWS_PROFILE}" 2>/dev/null || echo "us-east-1")

# shellcheck disable=SC2163
eval "${creds}"

# --- Run the container with resolved credentials ---
exec docker run --rm -it \
  --entrypoint bash \
  -v "${REPO_ROOT}:/workspace" \
  -w "/workspace" \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN \
  -e AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${PROFILE_REGION}}" \
  -e AWS_REGION="${AWS_REGION:-${PROFILE_REGION}}" \
  amazon/aws-cli:2.15.0 \
  "$@"
