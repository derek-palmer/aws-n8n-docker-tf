variable "domain_name" {
  type        = string
  description = "The target root domain name (e.g. example.com)"
}

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

output "route53_zone_id" {
  value = data.aws_route53_zone.main.zone_id
}
