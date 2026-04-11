# --- DLM IAM Role ---
# Allows AWS Data Lifecycle Manager to manage EBS snapshots for our instance
resource "aws_iam_role" "dlm_lifecycle_role" {
  count = var.enable_backups ? 1 : 0
  name  = "n8n-${var.env}-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "dlm.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "dlm_lifecycle_policy" {
  count      = var.enable_backups ? 1 : 0
  role       = aws_iam_role.dlm_lifecycle_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# --- DLM Policy ---
# Ensures the EC2 instance (and its attached volumes containing Postgres data)
# are automatically backed up on the configured schedule.
resource "aws_dlm_lifecycle_policy" "n8n_backup" {
  count              = var.enable_backups ? 1 : 0
  description        = "Backs up n8n ${var.env} EC2 instance every ${var.backup_interval_hours} hours retaining ${var.backup_retention_count} snapshots"
  execution_role_arn = aws_iam_role.dlm_lifecycle_role[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]

    schedule {
      name = "${var.backup_interval_hours}-Hour Snapshots ${var.backup_retention_count} retained"

      create_rule {
        interval      = var.backup_interval_hours
        interval_unit = "HOURS"
        times         = ["03:00"] # First run at 3 AM UTC, then repeats on the configured interval.
      }

      retain_rule {
        count = var.backup_retention_count
      }

      tags_to_add = {
        SnapshotCreator = "n8n-dlm-automation"
        Environment     = var.env
      }

      copy_tags = true
    }

    target_tags = {
      # This targets the exact EC2 instance tag defined in main.tf
      Name = "n8n-${var.env}-instance"
    }
  }
}
