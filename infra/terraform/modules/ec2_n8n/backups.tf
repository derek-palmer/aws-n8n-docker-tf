# --- DLM IAM Role ---
# Allows AWS Data Lifecycle Manager to manage EBS snapshots for our instance
resource "aws_iam_role" "dlm_lifecycle_role" {
  name = "n8n-${var.env}-dlm-role"

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
  role       = aws_iam_role.dlm_lifecycle_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# --- DLM Policy ---
# Ensures the EC2 instance (and its attached volumes containing Postgres data)
# are automatically backed up daily and retained for 14 days.
resource "aws_dlm_lifecycle_policy" "n8n_backup" {
  description        = "Daily backup for n8n ${var.env} EC2 instance"
  execution_role_arn = aws_iam_role.dlm_lifecycle_role.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]

    schedule {
      name = "Daily Snapshots (14 days retention)"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["07:00"] # 7 AM UTC / 2 AM EST
      }

      retain_rule {
        count = 14
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
