variable "env" {
  description = "Environment name (e.g., test, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the first public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_2_cidr" {
  description = "CIDR block for the second public subnet reserved for future expansion"
  type        = string
  default     = "10.0.2.0/24"
}

variable "az" {
  description = "Availability zone"
  type        = string
}

# --- Data ---
data "aws_availability_zones" "available" {
  state = "available"
}

# --- VPC ---
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "n8n-${var.env}-vpc"
  }
}

# --- Internet Gateway ---
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "n8n-${var.env}-igw"
  }
}

# --- Public Subnets ---
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.az
  # We purposefully enable auto-assigning public IPv4 addresses. This allows our 
  # EC2 instances in this subnet to natively reach out to the internet (for SSM, 
  # DockerHub, AWS APIs) via the Internet Gateway without requiring an expensive 
  # NAT Gateway ($32+/mo base cost).
  map_public_ip_on_launch = true

  tags = {
    Name = "n8n-${var.env}-public-subnet-1"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id     = aws_vpc.main.id
  cidr_block = var.public_subnet_2_cidr
  # Pick an AZ that is distinct from var.az
  availability_zone = element(tolist(setsubtract(data.aws_availability_zones.available.names, [var.az])), 0)
  # See comment in 'public' subnet for rationale avoiding NAT Gateway.
  map_public_ip_on_launch = true

  tags = {
    Name = "n8n-${var.env}-public-subnet-2"
  }
}

# --- Route Table ---
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "n8n-${var.env}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# --- Outputs ---
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public.id, aws_subnet.public_2.id]
}
