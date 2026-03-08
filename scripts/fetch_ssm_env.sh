#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/fetch_ssm_env.sh <env>
# Example: ./scripts/fetch_ssm_env.sh local

ENV=${1:-local}
OUTPUT_FILE=".env.${ENV}"

echo "Fetching SSM parameters for /n8n/${ENV}/..."

# Create secure temporary file and ensure cleanup on exit
umask 077
TMP_FILE=$(mktemp)
trap 'rm -f "${TMP_FILE}"' EXIT

# Use AWS CLI to get parameters by path (recursively), decrypt them, and format as KEY=VALUE
# Requirements: aws-cli
aws ssm get-parameters-by-path \
  --path "/n8n/${ENV}/" \
  --recursive \
  --with-decryption \
  --query "Parameters[*].[Name,Value]" \
  --output text | \
while read -r name value; do
  # Strip the common prefix /n8n/${ENV}/ and any potential leading slash
  key=${name#/n8n/${ENV}/}
  key=${key#/}
  
  # Convert to uppercase and replace slashes and hyphens with underscores, e.g., app/port -> APP_PORT
  env_key=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr '/-' '__')
  
  # Append to temp file
  echo "${env_key}=${value}" >> "${TMP_FILE}"
done

if [ -s "${TMP_FILE}" ]; then
    # Sort for consistency and move to target file
    sort "${TMP_FILE}" > "${OUTPUT_FILE}"
    echo "Successfully wrote parameters to ${OUTPUT_FILE}"
    
    # Secure the file (readable only by owner)
    chmod 600 "${OUTPUT_FILE}"
else
    echo "No parameters found for /n8n/${ENV}/. Is your AWS profile configured, or did you forget to create parameters?"
    exit 1
fi
