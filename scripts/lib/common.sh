#!/usr/bin/env bash
# =============================================================================
# scripts/lib/common.sh — Shared utilities sourced by all n8n scripts
# =============================================================================

# --- Colours ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
# Prints an informational message in cyan.
info()    { echo -e "${CYAN}[info]${NC}  $*"; }

# Prints a success message in green.
success() { echo -e "${GREEN}[ok]${NC}    $*"; }

# Prints a warning message in yellow.
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }

# Prints an error message in red to stderr and exits with status 1.
error()   { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# Prints a prompt message in yellow (used before read commands).
prompt()  { echo -e "${YELLOW}$*${NC}"; }

# --- resolve_aws_profile ---
# Verifies AWS credentials are active.
# When running inside Docker via aws_docker_run.sh, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, and AWS_SESSION_TOKEN are already set by the wrapper.
# This function simply confirms they work.
resolve_aws_profile() {
  # If static credentials already present (Docker path), just verify and return
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    aws sts get-caller-identity --query Account --output text &>/dev/null \
      || error "AWS credentials are set but not valid.\nRun 'awslogin' in your terminal and retry."
    return 0
  fi

  # If AWS_PROFILE is already explicitly exported and valid, just verify and return
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    aws sts get-caller-identity --query Account --output text &>/dev/null \
      || error "AWS credentials for profile '${AWS_PROFILE}' are not active.\nRun 'awslogin' in your terminal first, then retry."
    info "Using explicitly provided AWS profile: ${AWS_PROFILE}"
    return 0
  fi

  # No static credentials — try to pick a profile (host/direct-run path)
  local profiles
  profiles=$(aws configure list-profiles 2>/dev/null) \
    || error "Could not list AWS profiles. Is the AWS CLI configured?"
  [[ -z "${profiles}" ]] && error "No AWS profiles found. Configure one at ~/.aws/config"

  local profile_array=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && profile_array+=("${line}")
  done <<< "${profiles}"
  local profile_count="${#profile_array[@]}"

  if [[ "${profile_count}" -eq 1 ]]; then
    export AWS_PROFILE="${profile_array[0]}"
    info "Auto-selected AWS profile: ${AWS_PROFILE}"
  else
    echo ""
    echo -e "${CYAN}Select an AWS profile:${NC}"
    local i
    for i in "${!profile_array[@]}"; do
      echo "  $((i+1))) ${profile_array[$i]}"
    done
    echo ""
    local choice
    while true; do
      read -rp "  Enter number [1-${profile_count}]: " choice
      if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= profile_count )); then
        export AWS_PROFILE="${profile_array[$((choice-1))]}"
        break
      fi
      warn "Invalid selection, try again."
    done
    info "Using AWS profile: ${AWS_PROFILE}"
  fi

  aws sts get-caller-identity --query Account --output text &>/dev/null \
    || error "AWS credentials for profile '${AWS_PROFILE}' are not active.\nRun 'awslogin' in your terminal first, then retry."
}
