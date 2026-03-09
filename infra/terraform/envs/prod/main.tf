terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Backend settings are injected at init time by the Makefile and CI/CD pipeline.
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
  github_repo             = var.github_repo
  github_branch           = var.github_branch
  codestar_connection_arn = var.codestar_connection_arn
  n8n_upstream_ref        = var.n8n_upstream_ref
  ecr_repository_url      = var.ecr_repository_url
  ecr_repository_arn      = var.ecr_repository_arn
}

output "n8n_url" { value = module.stack.n8n_url }
output "instance_id" { value = module.stack.instance_id }
output "pipeline_name" { value = module.stack.pipeline_name }
output "application_pipeline_name" { value = module.stack.application_pipeline_name }
output "terraform_pipeline_name" { value = module.stack.terraform_pipeline_name }
