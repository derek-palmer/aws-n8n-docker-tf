variable "env" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "certificate_arn" { type = string }
variable "ec2_security_group_id" { type = string }

# --- ALB Security Group ---
resource "aws_security_group" "alb_sg" {
  name        = "n8n-${var.env}-alb-sg"
  description = "Security group for n8n ALB"
  vpc_id      = var.vpc_id

  # Allow inbound HTTP (IPv4 + IPv6) purely for redirect to HTTPS
  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # Allow inbound HTTPS (IPv4 + IPv6)
  ingress {
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "n8n-${var.env}-alb-sg"
  }
}

# Restrict outbound tightly to just the backend application
# Defined externally to break cyclical dependency between ALB SG and EC2 SG
resource "aws_security_group_rule" "alb_egress_to_ec2" {
  type                     = "egress"
  from_port                = 5678
  to_port                  = 5678
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb_sg.id
  source_security_group_id = var.ec2_security_group_id
}

# --- Application Load Balancer ---
resource "aws_lb" "main" {
  name               = "n8n-${var.env}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = var.subnet_ids

  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = {
    Name = "n8n-${var.env}-alb"
  }
}

# --- Target Group ---
resource "aws_lb_target_group" "n8n" {
  name     = "n8n-${var.env}-tg"
  port     = 5678
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 10
    matcher             = "200"
  }
}



# --- Listeners ---
# HTTP to HTTPS Redirect
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS Listener — TLS 1.3 policy (2021), the most modern AWS supports
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.n8n.arn
  }
}

# --- Outputs ---
output "target_group_arn" {
  value = aws_lb_target_group.n8n.arn
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}
output "alb_zone_id" {
  value = aws_lb.main.zone_id
}
output "security_group_id" {
  value = aws_security_group.alb_sg.id
}
