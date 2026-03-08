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
  description = "The subdomain to route to the ALB (e.g. n8n-test or n8n)"
  type        = string
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
