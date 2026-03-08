# --- env_stack/main.tf
# The single source of truth for wiring all n8n infrastructure modules together.
# This module is called once per environment from infra/terraform/envs/<env>/main.tf.

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
  source          = "../acm"
  domain_name     = var.domain_name
  subdomain       = var.subdomain
  route53_zone_id = module.route53.route53_zone_id
}

module "alb" {
  source          = "../alb"
  env             = var.env
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.public_subnet_ids
  certificate_arn = module.acm.certificate_arn
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
  subnet_id             = module.vpc.public_subnet_id
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

module "codepipeline" {
  source                  = "../codepipeline"
  env                     = var.env
  github_repo             = var.github_repo
  github_branch           = var.github_branch
  codestar_connection_arn = var.codestar_connection_arn
  codebuild_project_name  = module.codebuild.project_name
  codedeploy_app_name     = module.codedeploy.app_name
  codedeploy_group_name   = module.codedeploy.deployment_group_name
}

module "codebuild" {
  source                  = "../codebuild"
  env                     = var.env
  github_repo             = var.github_repo
  codestar_connection_arn = var.codestar_connection_arn
  ecr_repository_url      = var.ecr_repository_url
  artifact_bucket_name    = module.codepipeline.artifact_bucket_name
}
