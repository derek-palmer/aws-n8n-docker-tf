variable "domain_name" {}
variable "subdomain" {}
variable "alb_dns_name" {}
variable "alb_zone_id" {}

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# --- Alias Record ---
# Points the Subdomain (e.g. n8n.example.com) to the ALB
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.subdomain
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

output "route53_zone_id" {
  value = data.aws_route53_zone.main.zone_id
}

output "record_name" {
  value = aws_route53_record.app.name
}
