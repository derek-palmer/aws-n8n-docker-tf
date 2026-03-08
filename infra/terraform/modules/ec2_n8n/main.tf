variable "env" {
  description = "Environment name"
  type        = string
}
variable "vpc_id" {
  description = "ID of the VPC where the instance will reside"
  type        = string
}
variable "subnet_id" {
  description = "ID of the subnet where the instance will be launched"
  type        = string
}
variable "instance_profile_name" {
  description = "Name of the IAM instance profile to attach"
  type        = string
}
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t4g.micro"
}
variable "volume_size" {
  description = "Size of the root EBS volume in GB"
  type        = number
  default     = 30
}
variable "alb_security_group_id" {
  description = "Security group ID of the ALB to allow inbound HTTP traffic"
  type        = string
}
variable "docker_compose_version" {
  description = "The docker-compose plugin version to install"
  type        = string
  default     = "v2.24.5"
}

# Use the latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
}

# --- Security Group ---
resource "aws_security_group" "ec2_sg" {
  name        = "n8n-${var.env}-ec2-sg"
  description = "Security group for n8n EC2 instance"
  vpc_id      = var.vpc_id

  # Allow inbound HTTP from ALB only
  ingress {
    from_port       = 5678
    to_port         = 5678
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  # Allow all outbound
  # Note: Trivy flags this unrestricted egress (AWS-0104), but it is required for 
  # pulling container images from Docker Hub, accessing AWS APIs (SSM/KMS), and 
  # allowing n8n to integrate with external third-party webhooks/services.
  # TODO: Revisit by implementing VPC Endpoints and tighter CIDR blocks if restricted egress is mandated.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "n8n-${var.env}-ec2-sg"
  }
}

# --- EC2 Instance ---
resource "aws_instance" "n8n" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  monitoring    = true

  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = var.instance_profile_name

  # Note: No key_name provided because we do not allow SSH. 
  # Access is strictly via SSM Session Manager.

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  # Enforce IMDSv2 for enhanced SSRF protection
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = <<-EOF
  #!/bin/bash
  set -ex
  
  # Create a 2GB swap file to prevent OOM errors on smaller instances (e.g. t4g.micro)
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab

  # Update and install dependencies
  dnf update -y
  dnf install -y docker git
  
  # Start Docker
  systemctl enable docker
  systemctl start docker

  # Ensure ssm-user exists before we attach groups to it. 
  # SSM agent usually generates this on first connection, but this crashes cloud-init.
  id -u ssm-user &>/dev/null || useradd ssm-user
  usermod -aG docker ssm-user
  usermod -aG docker ec2-user

  # Install docker-compose plugin
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -SL "https://github.com/docker/compose/releases/download/${var.docker_compose_version}/docker-compose-linux-aarch64" -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  
  # Prepare app directory struct
  mkdir -p /opt/n8n-app
  chown -R ssm-user:ssm-user /opt/n8n-app
  
  # Note: 
  # The scripts/deploy.sh will actually pull the docker-compose source 
  # code down and start it in this directory later.
  EOF

  tags = {
    Name          = "n8n-${var.env}-instance"
    role          = "n8n"            # Used by CodeDeploy to identify instances
    "Patch Group" = "n8n-${var.env}" # Connects SSM Patch Manager baseline
  }

  # EBS volumes don't inherit instance tags automatically — set them explicitly
  # so DLM backup policy targeting and billing are both correct.
  volume_tags = {
    Name        = "n8n-${var.env}-root-volume"
    Environment = var.env
    Project     = "n8n-infra"
    ManagedBy   = "terraform"
  }
}

# --- Outputs ---
output "instance_id" {
  value = aws_instance.n8n.id
}
output "instance_public_ip" {
  value = aws_instance.n8n.public_ip
}
output "security_group_id" {
  value = aws_security_group.ec2_sg.id
}
