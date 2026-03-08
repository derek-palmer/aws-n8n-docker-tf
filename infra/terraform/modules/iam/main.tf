variable "env" {
  description = "Environment name"
  type        = string
}

variable "ssm_kms_key_id" {
  description = "Specific KMS Key ID used to encrypt SSM SecureStrings. If not provided, allows decryption via the SSM service broadly."
  type        = string
  default     = ""
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  log_group_arn = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/n8n/${var.env}:*"
}

# --- EC2 Instance Role ---
resource "aws_iam_role" "ec2_role" {
  name = "n8n-${var.env}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# --- SSM Managed Policy ---
# Allows Session Manager (SSH replacement), Patch Manager, etc.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allows the EC2 instance to communicate with the CodeDeploy service
resource "aws_iam_role_policy_attachment" "codedeploy_ec2" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforAWSCodeDeploy"
}

# --- Parameter Store Policy ---
# Least privilege: only allow reading parameters for THIS specific environment.
# Also includes kms:Decrypt so SecureString values can be decrypted.
resource "aws_iam_policy" "parameter_store" {
  name        = "n8n-${var.env}-parameter-store-policy"
  description = "Allow reading /n8n/${var.env} parameters"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:parameter/n8n/${var.env}/*"
      },
      merge({
        # Required for SecureString parameters encrypted with KMS
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.ssm_kms_key_id != "" ? "arn:aws:kms:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:key/${var.ssm_kms_key_id}" : "arn:aws:kms:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:key/*"
        }, var.ssm_kms_key_id == "" ? {
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${data.aws_region.current.id}.amazonaws.com"
          }
        }
      } : {})
    ]
  })
}

resource "aws_iam_role_policy_attachment" "parameter_store" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.parameter_store.arn
}

# --- CloudWatch Logs Policy ---
resource "aws_iam_policy" "cloudwatch" {
  name        = "n8n-${var.env}-cloudwatch-policy"
  description = "Allow docker logs to write to CloudWatch"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = local.log_group_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.cloudwatch.arn
}

# --- Instance Profile ---
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "n8n-${var.env}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# --- Outputs ---
output "instance_profile_name" {
  value = aws_iam_instance_profile.ec2_profile.name
}
