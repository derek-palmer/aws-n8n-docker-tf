#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/fetch_ssm_env.sh <env>
# Example: ./scripts/fetch_ssm_env.sh local

ENV=${1:-local}
OUTPUT_FILE=".env.${ENV}"
TMP_FILE="${OUTPUT_FILE}.tmp"

echo "Fetching SSM parameters for /n8n/${ENV}/..."

# Clear out any stale temp file content before starting
> "${TMP_FILE}"

# Use AWS CLI to get parameters by path (recursively), decrypt them, and format as KEY=VALUE
# Requirements: aws-cli
aws ssm get-parameters-by-path \
  --path "/n8n/${ENV}/" \
  --recursive \
  --with-decryption \
  --query "Parameters[*].[Name,Value]" \
  --output text | \
while read -r name value; do
  # Extract the last part of the parameter path, e.g., /n8n/dev/app/port -> port
  key=$(basename "$name")
  
  # Convert to uppercase and replace hyphens with underscores, e.g., port -> PORT
  env_key=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  
  # Append to temp file
  echo "${env_key}=${value}" >> "${TMP_FILE}"
done

if [ -s "${TMP_FILE}" ]; then
    # Sort for consistency and move to target file
    sort "${TMP_FILE}" > "${OUTPUT_FILE}"
    rm "${TMP_FILE}"
    echo "Successfully wrote parameters to ${OUTPUT_FILE}"
    
    # Secure the file (readable only by owner)
    chmod 600 "${OUTPUT_FILE}"
else
    echo "No parameters found for /n8n/${ENV}/. Is your AWS profile configured, or did you forget to create parameters?"
    exit 1
fi
