#!/usr/bin/env bash
# =============================================================================
# scripts/lib/aws_docker_run.sh
#
# Resolves AWS credentials on the HOST then passes them into a Docker container.
# Handles profile selection and works with SSO, IAM keys, and assume-role.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- Colours (minimal, since this runs on the host) ---
RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Prints an error message in red to stderr and exits with status 1.
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# Prints an informational message in cyan.
info()  { echo -e "${CYAN}[info]${NC}  $*"; }

# --- Determine which profile to use ---
if [[ -z "${AWS_PROFILE:-}" ]]; then
  # AWS_PROFILE not exported — pick from configured profiles
  profiles=$(aws configure list-profiles 2>/dev/null) \
    || error "Could not list AWS profiles. Is the AWS CLI configured?"
  [[ -z "${profiles}" ]] && error "No AWS profiles found. Configure one at ~/.aws/config"

  # Build array
  profile_array=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && profile_array+=("${line}")
  done <<< "${profiles}"
  profile_count="${#profile_array[@]}"

  if [[ "${profile_count}" -eq 1 ]]; then
    export AWS_PROFILE="${profile_array[0]}"
    info "Auto-selected AWS profile: ${AWS_PROFILE}"
  else
    echo ""
    echo -e "${CYAN}Select an AWS profile:${NC}"
    for i in "${!profile_array[@]}"; do
      echo "  $((i+1))) ${profile_array[$i]}"
    done
    echo ""
    while true; do
      read -rp "  Enter number [1-${profile_count}]: " choice
      if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= profile_count )); then
        export AWS_PROFILE="${profile_array[$((choice-1))]}"
        break
      fi
      echo -e "${YELLOW}[warn]${NC}  Invalid selection, try again."
    done
    info "Using AWS profile: ${AWS_PROFILE}"
  fi
else
  info "Using AWS profile: ${AWS_PROFILE}"
fi

# --- Resolve credentials for this profile on the host ---
# Use --format env (with 'export') so eval both sets AND exports the vars,
# making them available to `exec docker run -e AWS_ACCESS_KEY_ID ...`
if ! creds=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env 2>/dev/null); then
  error "Could not resolve credentials for profile '${AWS_PROFILE}'.\nRun 'awslogin' in your terminal first, then retry:\n  aws sso login --profile ${AWS_PROFILE}"
fi

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
  -e AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}" \
  -e AWS_REGION="${AWS_REGION:-us-east-1}" \
  amazon/aws-cli:latest \
  "$@"
