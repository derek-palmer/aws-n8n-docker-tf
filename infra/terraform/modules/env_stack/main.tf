# --- env_stack/main.tf
# The single source of truth for wiring all n8n infrastructure modules together.
# This module is called once per environment from infra/terraform/envs/<env>/main.tf.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "vpc" {
  source = "../vpc"
  env    = var.env
  az     = var.az
}

module "iam" {
  source = "../iam"
  env    = var.env
}

module "route53" {
  source      = "../route53"
  domain_name = var.domain_name
}

module "acm" {
  source      = "../acm"
  domain_name = var.domain_name
  subdomain   = var.subdomain
}

module "alb" {
  source                = "../alb"
  env                   = var.env
  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.public_subnet_ids
  certificate_arn       = module.acm.certificate_arn
  ec2_security_group_id = module.ec2_n8n.security_group_id
}

# Creates the A-record alias pointing the subdomain to the ALB
resource "aws_route53_record" "app" {
  zone_id = module.route53.route53_zone_id
  name    = var.subdomain
  type    = "A"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

module "ec2_n8n" {
  source                = "../ec2_n8n"
  env                   = var.env
  vpc_id                = module.vpc.vpc_id
  subnet_id             = module.vpc.public_subnet_ids[0]
  instance_profile_name = module.iam.instance_profile_name
  alb_security_group_id = module.alb.security_group_id
}

# Attaches the EC2 instance to the ALB Target Group
resource "aws_lb_target_group_attachment" "n8n" {
  target_group_arn = module.alb.target_group_arn
  target_id        = module.ec2_n8n.instance_id
  port             = 5678
}

module "ssm_automation" {
  source = "../ssm_automation"
  env    = var.env

  depends_on = [module.ec2_n8n]
}

module "codedeploy" {
  source = "../codedeploy"
  env    = var.env
}

# --- CI/CD Artifacts (Shared KMS + S3) ---

resource "aws_kms_key" "artifacts" {
  description             = "KMS key for CodePipeline artifacts in ${var.env}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "artifacts" {
  name          = "alias/n8n-${var.env}-artifacts"
  target_key_id = aws_kms_key.artifacts.key_id
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "n8n-${var.env}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # Safe for a CI artifact store

  tags = {
    Name = "n8n-${var.env}-pipeline-artifacts"
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.artifacts.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# --- CI/CD Pipelines ---

module "codepipeline" {
  source                  = "../codepipeline"
  env                     = var.env
  github_repo             = var.github_repo
  github_branch           = var.github_branch
  codestar_connection_arn = var.codestar_connection_arn
  codebuild_project_name  = module.codebuild.project_name
  codedeploy_app_name     = module.codedeploy.app_name
  codedeploy_group_name   = module.codedeploy.deployment_group_name
  artifact_bucket_name    = aws_s3_bucket.artifacts.id
  kms_key_arn             = aws_kms_key.artifacts.arn
}

module "codebuild" {
  source                  = "../codebuild"
  env                     = var.env
  github_repo             = var.github_repo
  codestar_connection_arn = var.codestar_connection_arn
  ecr_repository_url      = var.ecr_repository_url
  ecr_repository_arn      = var.ecr_repository_arn
  artifact_bucket_name    = aws_s3_bucket.artifacts.id
  kms_key_arn             = aws_kms_key.artifacts.arn
}
