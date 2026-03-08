variable "env" {
  description = "The environment name (e.g. test, prod)"
  type        = string
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- CodeDeploy IAM Role ---
resource "aws_iam_role" "codedeploy" {
  name = "n8n-${var.env}-codedeploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "codedeploy.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# AWS managed policy grants CodeDeploy the permissions it needs to interact with EC2
resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# --- CodeDeploy Application ---
resource "aws_codedeploy_app" "n8n" {
  compute_platform = "Server"
  name             = "n8n-${var.env}-app"
}

# --- CodeDeploy Deployment Group ---
# Targets EC2 instances tagged with `role=n8n` and `Environment=<env>`
resource "aws_codedeploy_deployment_group" "n8n" {
  app_name               = aws_codedeploy_app.n8n.name
  deployment_group_name  = "n8n-${var.env}-group"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.AllAtOnce"

  deployment_style {
    deployment_option = "WITHOUT_TRAFFIC_CONTROL"
    deployment_type   = "IN_PLACE"
  }

  # Match EC2 instances by their tags
  ec2_tag_set {
    ec2_tag_filter {
      key   = "role"
      type  = "KEY_AND_VALUE"
      value = "n8n"
    }

    ec2_tag_filter {
      key   = "Environment"
      type  = "KEY_AND_VALUE"
      value = var.env
    }
  }

  # Automatically roll back if deployment fails
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  tags = {
    Name = "n8n-${var.env}-codedeploy-group"
  }
}

# --- Outputs ---
output "app_name" {
  value = aws_codedeploy_app.n8n.name
}

output "deployment_group_name" {
  value = aws_codedeploy_deployment_group.n8n.deployment_group_name
}
