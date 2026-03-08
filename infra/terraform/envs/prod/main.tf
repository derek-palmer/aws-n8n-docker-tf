terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Uncomment and configure after creating your S3 state bucket:
  #   aws s3api create-bucket --bucket n8n-tf-state --region us-east-1
  #   aws dynamodb create-table --table-name n8n-tf-locks \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST
  # backend "s3" {
  #   bucket         = "n8n-tf-state"
  #   key            = "envs/prod/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "n8n-tf-locks"
  #   encrypt        = true
  # }
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
  ecr_repository_url      = var.ecr_repository_url
}

output "n8n_url"       { value = module.stack.n8n_url }
output "instance_id"   { value = module.stack.instance_id }
output "pipeline_name" { value = module.stack.pipeline_name }
