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

  artifact_bucket_name = aws_s3_bucket.artifacts.id
  artifact_kms_key_arn = aws_kms_key.artifacts.arn
  ecr_repository_arn   = var.ecr_repository_arn
}

module "route53" {
  source      = "../route53"
  domain_name = var.domain_name
}

module "ec2_n8n" {
  source                = "../ec2_n8n"
  env                   = var.env
  vpc_id                = module.vpc.vpc_id
  subnet_id             = module.vpc.public_subnet_ids[0]
  instance_profile_name = module.iam.instance_profile_name
  instance_ami_id       = var.instance_ami_id

  public_web_ingress_enabled = var.enable_public_endpoint
  enable_detailed_monitoring = var.enable_detailed_monitoring
  enable_backups             = var.enable_backups
  backup_interval_hours      = var.backup_interval_hours
  backup_retention_count     = var.backup_retention_count
}

resource "aws_eip" "app" {
  count  = var.enable_public_endpoint ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "n8n-${var.env}-eip"
  }
}

resource "aws_eip_association" "app" {
  count         = var.enable_public_endpoint ? 1 : 0
  allocation_id = aws_eip.app[0].id
  instance_id   = module.ec2_n8n.instance_id
}

resource "aws_route53_record" "app_direct" {
  count   = var.enable_public_endpoint ? 1 : 0
  zone_id = module.route53.route53_zone_id
  name    = var.subdomain
  type    = "A"
  ttl     = 300
  records = [aws_eip.app[0].public_ip]
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
  n8n_upstream_ref        = var.n8n_upstream_ref
  ecr_repository_url      = var.ecr_repository_url
  ecr_repository_arn      = var.ecr_repository_arn
  artifact_bucket_name    = aws_s3_bucket.artifacts.id
  kms_key_arn             = aws_kms_key.artifacts.arn
}
