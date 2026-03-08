variable "env" {
  description = "The environment name (e.g. test, prod)"
  type        = string
}

variable "github_repo" {
  description = "Full GitHub repository ID (e.g. your-org/your-repo)"
  type        = string
}

variable "codestar_connection_arn" {
  description = "ARN of the CodeStar Connection to GitHub"
  type        = string
}

variable "ecr_repository_url" {
  description = "URL of the ECR repository to push docker images to"
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository to push docker images to"
  type        = string
}

variable "artifact_bucket_name" {
  description = "S3 bucket name for CodePipeline artifacts"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the Customer Managed KMS Key encrypting the artifact bucket"
  type        = string
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --- CodeBuild IAM Role ---
resource "aws_iam_role" "codebuild" {
  name = "n8n-${var.env}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "codebuild.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "n8n-${var.env}-codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Write build logs to CloudWatch
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/n8n-${var.env}-build*"
      },
      {
        # Read artifacts from and write artifacts to the pipeline bucket
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"]
        Resource = [
          "arn:aws:s3:::${var.artifact_bucket_name}",
          "arn:aws:s3:::${var.artifact_bucket_name}/*"
        ]
      },
      {
        # Allow use of the KMS key for artifact encryption
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
      {
        # Authenticate to ECR
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Push images to the specific ECR repository
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage"
        ]
        Resource = var.ecr_repository_arn
      },
      {
        # Allow use of the CodeStar connection to clone from GitHub
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = var.codestar_connection_arn
      }
    ]
  })
}

# --- CodeBuild Project ---
resource "aws_codebuild_project" "n8n" {
  name          = "n8n-${var.env}-build"
  description   = "Builds and pushes the n8n docker-compose stack for ${var.env}"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20 # minutes

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    # ARM-based build image to match the Graviton (arm64) EC2 target
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-aarch64-standard:3.0"
    type                        = "ARM_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # Required for Docker-in-Docker builds

    environment_variable {
      name  = "ENV"
      value = var.env
    }

    environment_variable {
      name  = "ECR_REPO_URL"
      value = var.ecr_repository_url
    }

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = data.aws_region.current.id
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/n8n-${var.env}-build"
      stream_name = "build-log"
    }
  }

  tags = {
    Name = "n8n-${var.env}-codebuild"
  }
}

# --- Outputs ---
output "project_name" {
  value = aws_codebuild_project.n8n.name
}
