variable "domain_name" {}

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

output "route53_zone_id" {
  value = data.aws_route53_zone.main.zone_id
}
