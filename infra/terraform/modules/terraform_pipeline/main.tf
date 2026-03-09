variable "env" {
  description = "The environment name (e.g. test, prod)"
  type        = string
}

variable "aws_region" {
  description = "The AWS region for this environment"
  type        = string
}

variable "az" {
  description = "The availability zone for this environment"
  type        = string
}

variable "domain_name" {
  description = "The root domain name for this environment"
  type        = string
}

variable "subdomain" {
  description = "The n8n subdomain for this environment"
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

variable "n8n_upstream_ref" {
  description = "The upstream n8n docker image reference"
  type        = string
}

variable "ecr_repository_url" {
  description = "URL of the ECR repository used by the application pipeline"
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository used by the application pipeline"
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

variable "terraform_version" {
  description = "Terraform version installed in the CodeBuild jobs"
  type        = string
  default     = "1.7.5"
}

variable "codebuild_image" {
  description = "CodeBuild image used for Terraform validation and apply jobs"
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  tf_working_dir    = "infra/terraform/envs/${var.env}"
  state_bucket_name = "n8n-tf-state-${data.aws_caller_identity.current.account_id}"
  iam_role_arns = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/n8n-${var.env}-codebuild-role",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/n8n-${var.env}-codepipeline-role",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/n8n-${var.env}-codedeploy-role",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/n8n-${var.env}-dlm-role",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/n8n-${var.env}-ec2-role",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/n8n-${var.env}-terraform-codebuild-role",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/n8n-${var.env}-terraform-codepipeline-role"
  ]
  iam_pass_services = [
    "codebuild.amazonaws.com",
    "codedeploy.amazonaws.com",
    "codepipeline.amazonaws.com",
    "dlm.amazonaws.com",
    "ec2.amazonaws.com"
  ]

  common_environment_variables = {
    AWS_DEFAULT_REGION             = var.aws_region
    AWS_REGION                     = var.aws_region
    TERRAFORM_VERSION              = var.terraform_version
    TF_ENV                         = var.env
    TF_INPUT                       = "0"
    TF_IN_AUTOMATION               = "1"
    TF_VAR_aws_region              = var.aws_region
    TF_VAR_az                      = var.az
    TF_VAR_codestar_connection_arn = var.codestar_connection_arn
    TF_VAR_domain_name             = var.domain_name
    TF_VAR_ecr_repository_arn      = var.ecr_repository_arn
    TF_VAR_ecr_repository_url      = var.ecr_repository_url
    TF_VAR_env                     = var.env
    TF_VAR_github_branch           = var.github_branch
    TF_VAR_github_repo             = var.github_repo
    TF_VAR_n8n_upstream_ref        = var.n8n_upstream_ref
    TF_VAR_subdomain               = var.subdomain
    TF_WORKING_DIR                 = local.tf_working_dir
  }
}

resource "aws_iam_role" "codebuild" {
  name = "n8n-${var.env}-terraform-codebuild-role"

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
  name = "n8n-${var.env}-terraform-codebuild-policy"
  role = aws_iam_role.codebuild.id

  # Broad within the services this stack actually manages; scoped for logs/state/artifacts.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CodeBuildLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/n8n-${var.env}-terraform-plan",
          "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/n8n-${var.env}-terraform-plan:*",
          "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/n8n-${var.env}-terraform-apply",
          "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/n8n-${var.env}-terraform-apply:*"
        ]
      },
      {
        Sid    = "TerraformStateLocking"
        Effect = "Allow"
        Action = [
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:table/n8n-tf-locks"
      },
      {
        Sid    = "TerraformStateBucket"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:ListBucket",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${local.state_bucket_name}",
          "arn:aws:s3:::${local.state_bucket_name}/*"
        ]
      },
      {
        Sid    = "ArtifactBucketManagement"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:DeleteBucketPublicAccessBlock",
          "s3:DeleteBucketTagging",
          "s3:DeleteBucketOwnershipControls",
          "s3:DeleteObject",
          "s3:GetBucketLocation",
          "s3:GetBucketOwnershipControls",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetBucketTagging",
          "s3:GetBucketVersioning",
          "s3:GetEncryptionConfiguration",
          "s3:GetLifecycleConfiguration",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket",
          "s3:PutBucketOwnershipControls",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketTagging",
          "s3:PutBucketVersioning",
          "s3:PutEncryptionConfiguration",
          "s3:PutLifecycleConfiguration",
          "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.artifact_bucket_name}",
          "arn:aws:s3:::${var.artifact_bucket_name}/*"
        ]
      },
      {
        Sid    = "ScopedConnectionUse"
        Effect = "Allow"
        Action = [
          "codeconnections:GetConnection",
          "codeconnections:UseConnection",
          "codestar-connections:GetConnection",
          "codestar-connections:UseConnection"
        ]
        Resource = var.codestar_connection_arn
      },
      {
        Sid    = "ManageAcmCertificates"
        Effect = "Allow"
        Action = [
          "acm:AddTagsToCertificate",
          "acm:DeleteCertificate",
          "acm:DescribeCertificate",
          "acm:ListCertificates",
          "acm:ListTagsForCertificate",
          "acm:RemoveTagsFromCertificate",
          "acm:RequestCertificate"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageCodeBuildProjects"
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetProjects",
          "codebuild:CreateProject",
          "codebuild:DeleteProject",
          "codebuild:ListProjects",
          "codebuild:ListTagsForResource",
          "codebuild:TagResource",
          "codebuild:UntagResource",
          "codebuild:UpdateProject"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageCodeDeployResources"
        Effect = "Allow"
        Action = [
          "codedeploy:CreateApplication",
          "codedeploy:CreateDeploymentGroup",
          "codedeploy:DeleteApplication",
          "codedeploy:DeleteDeploymentGroup",
          "codedeploy:GetApplication",
          "codedeploy:GetDeploymentGroup",
          "codedeploy:ListApplications",
          "codedeploy:ListTagsForResource",
          "codedeploy:TagResource",
          "codedeploy:UntagResource",
          "codedeploy:UpdateDeploymentGroup"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageCodePipelineResources"
        Effect = "Allow"
        Action = [
          "codepipeline:CreatePipeline",
          "codepipeline:DeletePipeline",
          "codepipeline:GetPipeline",
          "codepipeline:GetPipelineState",
          "codepipeline:ListPipelines",
          "codepipeline:ListTagsForResource",
          "codepipeline:TagResource",
          "codepipeline:UntagResource",
          "codepipeline:UpdatePipeline"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageDlmPolicies"
        Effect = "Allow"
        Action = [
          "dlm:CreateLifecyclePolicy",
          "dlm:DeleteLifecyclePolicy",
          "dlm:GetLifecyclePolicies",
          "dlm:ListTagsForResource",
          "dlm:TagResource",
          "dlm:UntagResource",
          "dlm:UpdateLifecyclePolicy"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageEc2Infrastructure"
        Effect = "Allow"
        Action = [
          "ec2:AssociateIamInstanceProfile",
          "ec2:AssociateRouteTable",
          "ec2:AttachInternetGateway",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CreateInternetGateway",
          "ec2:CreateRoute",
          "ec2:CreateRouteTable",
          "ec2:CreateSecurityGroup",
          "ec2:CreateSubnet",
          "ec2:CreateTags",
          "ec2:CreateVpc",
          "ec2:DeleteInternetGateway",
          "ec2:DeleteRoute",
          "ec2:DeleteRouteTable",
          "ec2:DeleteSecurityGroup",
          "ec2:DeleteSubnet",
          "ec2:DeleteTags",
          "ec2:DeleteVpc",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeIamInstanceProfileAssociations",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceAttribute",
          "ec2:DescribeInstances",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroupRules",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVpcs",
          "ec2:DetachInternetGateway",
          "ec2:DisassociateIamInstanceProfile",
          "ec2:DisassociateRouteTable",
          "ec2:ModifyInstanceAttribute",
          "ec2:ModifyInstanceMetadataOptions",
          "ec2:ModifySubnetAttribute",
          "ec2:ModifyVpcAttribute",
          "ec2:MonitorInstances",
          "ec2:RebootInstances",
          "ec2:ReplaceIamInstanceProfileAssociation",
          "ec2:ReplaceRouteTableAssociation",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RunInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:TerminateInstances"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageElasticLoadBalancing"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageRoute53Records"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:GetChange",
          "route53:GetHostedZone",
          "route53:ListHostedZonesByName",
          "route53:ListResourceRecordSets"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageSsmAutomation"
        Effect = "Allow"
        Action = [
          "ssm:AddTagsToResource",
          "ssm:CreateAssociation",
          "ssm:CreateMaintenanceWindow",
          "ssm:CreatePatchBaseline",
          "ssm:DeleteAssociation",
          "ssm:DeleteMaintenanceWindow",
          "ssm:DeletePatchBaseline",
          "ssm:DeregisterPatchBaselineForPatchGroup",
          "ssm:DeregisterTargetFromMaintenanceWindow",
          "ssm:DeregisterTaskFromMaintenanceWindow",
          "ssm:DescribeAssociation",
          "ssm:DescribeMaintenanceWindowTargets",
          "ssm:DescribeMaintenanceWindowTasks",
          "ssm:DescribeMaintenanceWindows",
          "ssm:DescribePatchBaselines",
          "ssm:GetMaintenanceWindow",
          "ssm:GetMaintenanceWindowTask",
          "ssm:GetPatchBaseline",
          "ssm:GetPatchBaselineForPatchGroup",
          "ssm:ListAssociations",
          "ssm:ListTagsForResource",
          "ssm:RegisterPatchBaselineForPatchGroup",
          "ssm:RegisterTargetWithMaintenanceWindow",
          "ssm:RegisterTaskWithMaintenanceWindow",
          "ssm:RemoveTagsFromResource",
          "ssm:UpdateAssociation",
          "ssm:UpdateMaintenanceWindow",
          "ssm:UpdatePatchBaseline"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageIamResources"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:AttachRolePolicy",
          "iam:CreateInstanceProfile",
          "iam:CreatePolicy",
          "iam:CreatePolicyVersion",
          "iam:CreateRole",
          "iam:CreateServiceLinkedRole",
          "iam:DeleteInstanceProfile",
          "iam:DeletePolicy",
          "iam:DeletePolicyVersion",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:DetachRolePolicy",
          "iam:GetInstanceProfile",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:ListPolicyTags",
          "iam:ListPolicyVersions",
          "iam:ListRolePolicies",
          "iam:ListRoleTags",
          "iam:PutRolePolicy",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:TagPolicy",
          "iam:TagRole",
          "iam:UntagInstanceProfile",
          "iam:UntagPolicy",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy"
        ]
        Resource = "*"
      },
      {
        Sid      = "PassManagedRolesOnly"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = local.iam_role_arns
        Condition = {
          StringEquals = {
            "iam:PassedToService" = local.iam_pass_services
          }
        }
      },
      {
        Sid    = "ManageKmsResources"
        Effect = "Allow"
        Action = [
          "kms:CancelKeyDeletion",
          "kms:CreateAlias",
          "kms:CreateKey",
          "kms:DeleteAlias",
          "kms:DescribeKey",
          "kms:DisableKeyRotation",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListAliases",
          "kms:ListResourceTags",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:UpdateAlias",
          "kms:UpdateKeyDescription"
        ]
        Resource = "*"
      },
      {
        Sid    = "UseArtifactKmsKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_key_arn
      },
      {
        Sid    = "ReadAccountMetadata"
        Effect = "Allow"
        Action = [
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_codebuild_project" "plan" {
  name          = "n8n-${var.env}-terraform-plan"
  description   = "Validates and plans Terraform changes for ${var.env}"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  depends_on = [aws_iam_role_policy.codebuild]

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    dynamic "environment_variable" {
      for_each = local.common_environment_variables
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform-buildspec-plan.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/n8n-${var.env}-terraform-plan"
      stream_name = "terraform-plan"
    }
  }

  tags = {
    Name = "n8n-${var.env}-terraform-plan"
  }
}

resource "aws_codebuild_project" "apply" {
  name          = "n8n-${var.env}-terraform-apply"
  description   = "Applies Terraform changes for ${var.env}"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  depends_on = [aws_iam_role_policy.codebuild]

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    dynamic "environment_variable" {
      for_each = local.common_environment_variables
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform-buildspec-apply.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/n8n-${var.env}-terraform-apply"
      stream_name = "terraform-apply"
    }
  }

  tags = {
    Name = "n8n-${var.env}-terraform-apply"
  }
}

resource "aws_iam_role" "codepipeline" {
  name = "n8n-${var.env}-terraform-codepipeline-role"

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
  name = "n8n-${var.env}-terraform-codepipeline-policy"
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
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = [aws_codebuild_project.plan.arn, aws_codebuild_project.apply.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = var.codestar_connection_arn
      }
    ]
  })
}

resource "aws_codepipeline" "terraform" {
  name     = "n8n-${var.env}-terraform-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = var.artifact_bucket_name
    type     = "S3"

    encryption_key {
      id   = var.kms_key_arn
      type = "KMS"
    }
  }

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
        BranchName           = var.github_branch
        ConnectionArn        = var.codestar_connection_arn
        DetectChanges        = "true"
        FullRepositoryId     = var.github_repo
        OutputArtifactFormat = "CODEBUILD_CLONE_REF"
      }
    }
  }

  stage {
    name = "ValidatePlan"

    action {
      name             = "ValidatePlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["tfplan_output"]

      configuration = {
        ProjectName = aws_codebuild_project.plan.name
      }
    }
  }

  stage {
    name = "Apply"

    action {
      name            = "Apply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output", "tfplan_output"]

      configuration = {
        PrimarySource = "source_output"
        ProjectName   = aws_codebuild_project.apply.name
      }
    }
  }

  tags = {
    Name = "n8n-${var.env}-terraform-pipeline"
  }
}

output "pipeline_name" {
  value = aws_codepipeline.terraform.name
}

output "plan_project_name" {
  value = aws_codebuild_project.plan.name
}

output "apply_project_name" {
  value = aws_codebuild_project.apply.name
}
