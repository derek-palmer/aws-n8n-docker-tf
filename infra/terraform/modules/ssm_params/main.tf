variable "env" {}

# A skeleton module to show how to define parameter hierarchies explicitly in Terraform
# Often, secrets like DB passwords are created manually, while non-sensitive config
# can be managed via IaC.

resource "aws_ssm_parameter" "app_host" {
  name  = "/n8n/${var.env}/app/host"
  type  = "String"
  value = "n8n-${var.env}.example.com" # Overridden in variables usually
}

resource "aws_ssm_parameter" "app_protocol" {
  name  = "/n8n/${var.env}/app/protocol"
  type  = "String"
  value = "https"
}

# Example of a SecureString where you might supply the value natively 
# or ignore changes via lifecycle block to prevent TF from storing plain text state forever.
resource "aws_ssm_parameter" "db_password" {
  name  = "/n8n/${var.env}/db/postgres/password"
  type  = "SecureString"
  value = "ChangeMe123!" # Ideally injected via external secrets manager

  lifecycle {
    ignore_changes = [value]
  }
}
