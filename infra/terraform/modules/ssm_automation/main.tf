variable "env" {}

# Sets up a Patch Manager baseline for the instance to keep it secure
resource "aws_ssm_patch_baseline" "n8n_amazon_linux_2023" {
  name             = "n8n-${var.env}-al2023-baseline"
  description      = "Patch baseline for n8n AL2023"
  operating_system = "AMAZON_LINUX_2023"

  approval_rule {
    approve_after_days = 7
    compliance_level   = "CRITICAL"
    patch_filter {
      key    = "CLASSIFICATION"
      values = ["Security"]
    }
    patch_filter {
      key    = "SEVERITY"
      values = ["Critical", "Important"]
    }
  }
}

# Assign the patch baseline to our EC2 instance group
resource "aws_ssm_patch_group" "n8n" {
  baseline_id = aws_ssm_patch_baseline.n8n_amazon_linux_2023.id
  patch_group = "n8n-${var.env}"
}

# Create a Maintenance Window for automated patching (Every Sunday at 2 AM)
resource "aws_ssm_maintenance_window" "n8n_patching" {
  name     = "n8n-${var.env}-maintenance-window"
  schedule = "cron(0 2 ? * SUN *)"
  duration = 3
  cutoff   = 1
}

# Target instances with the specific patch group tag
resource "aws_ssm_maintenance_window_target" "n8n_patching_target" {
  window_id     = aws_ssm_maintenance_window.n8n_patching.id
  resource_type = "INSTANCE"

  targets {
    key    = "tag:Patch Group"
    values = ["n8n-${var.env}"]
  }
}

# Create a task to run the patch installation during the maintenance window
resource "aws_ssm_maintenance_window_task" "n8n_patching_task" {
  window_id       = aws_ssm_maintenance_window.n8n_patching.id
  task_type       = "RUN_COMMAND"
  task_arn        = "AWS-RunPatchBaseline"
  priority        = 1
  max_concurrency = "1"
  max_errors      = "1"

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.n8n_patching_target.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      parameter {
        name   = "Operation"
        values = ["Install"]
      }
    }
  }
}

# Note: The EC2 instance must have the tag `Patch Group: n8n-${var.env}` to be
# enrolled in this baseline. This is set in the ec2_n8n module.

# --- CodeDeploy Agent Installation via SSM ---
# Automatically install and update the CodeDeploy agent using SSM Distributor
resource "aws_ssm_association" "codedeploy_agent" {
  name             = "AWS-ConfigureAWSPackage"
  association_name = "n8n-${var.env}-codedeploy-agent-install"

  targets {
    key    = "tag:Patch Group"
    values = ["n8n-${var.env}"]
  }

  parameters = {
    action = "Install"
    name   = "AWSCodeDeployAgent"
  }

  # Avoid racing with cloud-init (which installs Ruby, a prerequisite).
  # Only run on the scheduled interval, not immediately on instance registration.
  apply_only_at_cron_interval = true
  schedule_expression         = "rate(10 minutes)"
}
