# Variables passed in from terraform.tfvars and forwarded to the env_stack module.
# Declarations must exist in the root module for Terraform to accept tfvars values.
# All descriptions and logic live in modules/env_stack/variables.tf.

variable "env" { type = string }
variable "aws_region" { type = string }
variable "az" { type = string }

variable "domain_name" { type = string }
variable "subdomain" { type = string }

variable "github_repo" { type = string }
variable "github_branch" {
  type    = string
  default = "main"
}
variable "n8n_upstream_ref" {
  type    = string
  default = "n8nio/n8n:latest"
}
variable "codestar_connection_arn" { type = string }
variable "ecr_repository_url" { type = string }
variable "ecr_repository_arn" { type = string }
