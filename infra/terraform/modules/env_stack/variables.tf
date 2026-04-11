# --- env_stack/variables.tf
# All input variables for a full n8n environment stack.
# These are declared here once and passed in from infra/terraform/envs/<env>/main.tf.

variable "env" {
  description = "The environment name (e.g. test, prod)"
  type        = string
}

variable "aws_region" {
  description = "The AWS region to deploy to"
  type        = string
}

variable "az" {
  description = "The availability zone to deploy resources into (e.g. us-east-1a)"
  type        = string
}

# --- DNS ---

variable "domain_name" {
  description = "The root domain name (e.g. example.com)"
  type        = string
}

variable "subdomain" {
  description = "The subdomain to route to the public endpoint (e.g. n8n-test or n8n)"
  type        = string
}

variable "enable_public_endpoint" {
  description = "Whether to expose the environment publicly via Route 53 and an Elastic IP"
  type        = bool
  default     = true
}

variable "instance_ami_id" {
  description = "Optional AMI ID to pin the EC2 instance to. Leave null to use the latest Amazon Linux 2023 image."
  type        = string
  default     = null
}

variable "enable_detailed_monitoring" {
  description = "Whether to enable paid 1-minute EC2 detailed monitoring"
  type        = bool
  default     = false
}

variable "enable_backups" {
  description = "Whether to enable automated DLM EBS snapshots for the instance"
  type        = bool
  default     = true
}

variable "backup_interval_hours" {
  description = "Snapshot interval in hours when backups are enabled"
  type        = number
  default     = 24

  validation {
    condition     = var.backup_interval_hours >= 1 && floor(var.backup_interval_hours) == var.backup_interval_hours
    error_message = "backup_interval_hours must be a whole number greater than or equal to 1."
  }
}

variable "backup_retention_count" {
  description = "How many snapshots to retain when backups are enabled"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_count >= 1 && floor(var.backup_retention_count) == var.backup_retention_count
    error_message = "backup_retention_count must be a whole number greater than or equal to 1."
  }
}

# --- CI/CD ---

variable "github_repo" {
  description = "Full GitHub repository ID (e.g. your-org/your-repo)"
  type        = string
}

variable "github_branch" {
  description = "The branch to trigger deployments from"
  type        = string
  default     = "main"
}

variable "n8n_upstream_ref" {
  description = "The upstream n8n docker image reference to pull (e.g. n8nio/n8n:latest or n8nio/n8n@sha256:...)"
  type        = string
  default     = "n8nio/n8n:latest"
}

variable "codestar_connection_arn" {
  description = "ARN of the AWS CodeStar Connection to GitHub"
  type        = string
}

variable "ecr_repository_url" {
  description = "URL of the ECR repository to push/pull Docker images"
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the exact ECR repository (for CodeBuild Push IAM policies)"
  type        = string
}
