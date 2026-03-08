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

# Note: The EC2 instance must have the tag `Patch Group: n8n-${var.env}` to be
# enrolled in this baseline. This is set in the ec2_n8n module.
