terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial config: values live in backend.hcl (gitignored), written by
  # `make bootstrap` and passed by `make tf-init`.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.env
      Project     = "n8n-infra"
      ManagedBy   = "terraform"
    }
  }
}

module "stack" {
  source = "../../modules/env_stack"

  env                     = var.env
  aws_region              = var.aws_region
  az                      = var.az
  domain_name             = var.domain_name
  subdomain               = var.subdomain
  instance_ami_id         = var.instance_ami_id
  github_repo             = var.github_repo
  github_branch           = var.github_branch
  codestar_connection_arn = var.codestar_connection_arn
  n8n_upstream_ref        = var.n8n_upstream_ref
  ecr_repository_url      = var.ecr_repository_url
  ecr_repository_arn      = var.ecr_repository_arn
  enable_public_endpoint  = true

  enable_detailed_monitoring = false
  enable_backups             = true
  backup_interval_hours      = 24
  backup_retention_count     = 7
}

output "n8n_url" { value = module.stack.n8n_url }
output "instance_id" { value = module.stack.instance_id }
output "pipeline_name" { value = module.stack.pipeline_name }
