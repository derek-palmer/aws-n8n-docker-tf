variable "env" {
  description = "The environment name (e.g. test, prod)"
  type        = string
}

variable "github_repo" {
  description = "Full GitHub repository ID (e.g. your-org/your-repo)"
  type        = string
}

variable "github_branch" {
  description = "The branch to use as the source (e.g. main)"
  type        = string
  default     = "main"
}

variable "codestar_connection_arn" {
  description = "ARN of the CodeStar Connection to GitHub"
  type        = string
}

variable "codebuild_project_name" {
  description = "Name of the CodeBuild project"
  type        = string
}

variable "codedeploy_app_name" {
  description = "Name of the CodeDeploy application"
  type        = string
}

variable "codedeploy_group_name" {
  description = "Name of the CodeDeploy deployment group"
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

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}



# --- CodePipeline IAM Role ---
resource "aws_iam_role" "codepipeline" {
  name = "n8n-${var.env}-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "codepipeline.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "n8n-${var.env}-codepipeline-policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
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
        # Allow pipeline to trigger the CodeBuild project
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = "arn:aws:codebuild:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:project/${var.codebuild_project_name}"
      },
      {
        # Allow pipeline to create CodeDeploy deployments
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment",
          "codedeploy:GetDeployment",
          "codedeploy:GetApplication",
          "codedeploy:GetApplicationRevision",
          "codedeploy:RegisterApplicationRevision",
          "codedeploy:GetDeploymentConfig"
        ]
        Resource = [
          "arn:aws:codedeploy:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:application:${var.codedeploy_app_name}",
          "arn:aws:codedeploy:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:deploymentgroup:${var.codedeploy_app_name}/${var.codedeploy_group_name}",
          "arn:aws:codedeploy:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:deploymentconfig:*"
        ]
      },
      {
        # Allow use of the CodeStar connection to pull from GitHub
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = var.codestar_connection_arn
      }
    ]
  })
}

# --- CodePipeline ---
resource "aws_codepipeline" "n8n" {
  name     = "n8n-${var.env}-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = var.artifact_bucket_name
    type     = "S3"

    encryption_key {
      id   = var.kms_key_arn
      type = "KMS"
    }
  }

  # Stage 1: Pull source from GitHub via CodeStar Connection
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = var.codestar_connection_arn
        FullRepositoryId     = var.github_repo
        BranchName           = var.github_branch
        DetectChanges        = "true" # Auto-trigger on push
        OutputArtifactFormat = "CODEBUILD_CLONE_REF"
      }
    }
  }

  # Stage 2: Build and push Docker images via CodeBuild
  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"

      configuration = {
        ProjectName = var.codebuild_project_name
      }
    }
  }

  # Stage 3: Deploy to EC2 via CodeDeploy
  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        ApplicationName     = var.codedeploy_app_name
        DeploymentGroupName = var.codedeploy_group_name
      }
    }
  }

  tags = {
    Name = "n8n-${var.env}-pipeline"
  }
}

# --- Outputs ---
output "pipeline_name" {
  value = aws_codepipeline.n8n.name
}


