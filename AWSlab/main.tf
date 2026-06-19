terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.8" # 5.8+ required for aws_ec2_instance_connect_endpoint
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Applies owner=training to every resource automatically
  default_tags {
    tags = {
      owner = "training"
    }
  }
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "vpc-ailab-${var.participant_name}" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "igw-ailab" }
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

# Public subnet — hosts the NAT Gateway only; no instances
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.3.0/27"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false
  tags = { Name = "snet-public" }
}

resource "aws_subnet" "app" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false
  tags = { Name = "snet-app" }
}

resource "aws_subnet" "db" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false
  tags = { Name = "snet-db" }
}

# ---------------------------------------------------------------------------
# NAT Gateway — outbound internet for package installs and SSM on Windows
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.lab]
  tags       = { Name = "eip-nat-ailab" }
}

resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.lab]
  tags          = { Name = "nat-ailab" }
}

# ---------------------------------------------------------------------------
# Route Tables
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
  tags = { Name = "rt-public" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }
  tags = { Name = "rt-private" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  subnet_id      = aws_subnet.app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  subnet_id      = aws_subnet.db.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

# EICE endpoint SG — egress only to port 22 on private subnets
resource "aws_security_group" "eice" {
  name        = "sg-eice"
  description = "EC2 Instance Connect Endpoint — egress to SSH targets only"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "SSH to app and db subnets"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24", "10.0.2.0/24"]
  }

  tags = { Name = "sg-eice" }
}

# App tier SG — SSH only from EICE endpoint
resource "aws_security_group" "app" {
  name        = "sg-app"
  description = "App tier — SSH from EICE only"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description     = "SSH from EICE endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-app" }
}

# DB tier SG — PostgreSQL from app subnet, SSH from EICE
resource "aws_security_group" "db" {
  name        = "sg-db"
  description = "DB tier — Postgres from app subnet, SSH from EICE"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description     = "SSH from EICE endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice.id]
  }

  ingress {
    description = "PostgreSQL from app subnet"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-db" }
}

# Windows SG — no inbound ports; RDP delivered via SSM Fleet Manager tunnel
resource "aws_security_group" "win" {
  name        = "sg-win"
  description = "Windows VM — SSM Fleet Manager RDP, no inbound ports"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "Outbound for SSM and Windows Update"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-win" }
}

# ---------------------------------------------------------------------------
# EC2 Instance Connect Endpoint (Azure Bastion equivalent)
# Provides SSH access to private instances without a public IP or jump box.
# Usage: aws ec2-instance-connect ssh --instance-id <id> --os-user ubuntu
# ---------------------------------------------------------------------------
resource "aws_ec2_instance_connect_endpoint" "lab" {
  subnet_id          = aws_subnet.app.id
  security_group_ids = [aws_security_group.eice.id]
  preserve_client_ip = false
  tags               = { Name = "eice-ailab" }
}

# ---------------------------------------------------------------------------
# IAM — SSM instance profile (required for Windows Fleet Manager RDP)
# Also applied to Linux VMs to allow SSM Run Command and Session Manager.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ssm" {
  name = "role-ssm-${var.participant_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "role-ssm-${var.participant_name}" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "profile-ssm-${var.participant_name}"
  role = aws_iam_role.ssm.name
  tags = { Name = "profile-ssm-${var.participant_name}" }
}

# ---------------------------------------------------------------------------
# AMI Data Sources — always resolves to the latest published image
# ---------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# EC2 Instances
# ---------------------------------------------------------------------------

# App VM — Ubuntu 22.04 | t3.large (2 vCPU / 8 GiB) ≈ Azure Standard_B2ms
resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  subnet_id              = aws_subnet.app.id
  vpc_security_group_ids = [aws_security_group.app.id]
  private_ip             = "10.0.1.10"
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  monitoring             = true # detailed CloudWatch metrics (1-min intervals)

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "vm-app" }
}

# DB VM — Ubuntu 22.04 | t3.large | bootstrapped with PostgreSQL 14
resource "aws_instance" "db" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.large"
  subnet_id                   = aws_subnet.db.id
  vpc_security_group_ids      = [aws_security_group.db.id]
  private_ip                  = "10.0.2.10"
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  monitoring                  = true
  user_data                   = file("${path.module}/cloud-init-db.yaml")
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "vm-db" }
}

# Windows VM — Server 2022 | t3.medium (2 vCPU / 4 GiB) ≈ Azure Standard_B2s
# RDP access: AWS Console → Systems Manager → Fleet Manager → Node Tools → Connect
resource "aws_instance" "win" {
  ami                    = data.aws_ami.windows.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.app.id
  vpc_security_group_ids = [aws_security_group.win.id]
  private_ip             = "10.0.1.20"
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  monitoring             = true

  # Sets the local Administrator password at first boot via EC2Launch v2
  user_data = <<-EOT
    <powershell>
    net user Administrator "${var.admin_password}"
    </powershell>
  EOT

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 128
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "vm-win" }
}

# ---------------------------------------------------------------------------
# S3 Bucket (Azure StorageV2 equivalent)
# Versioning replaces Azure soft-delete; noncurrent version expiry = 30 days
# NOTE: S3 bucket names are globally unique — add a suffix if name conflicts
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "lab" {
  bucket        = "stailab-${var.participant_name}"
  force_destroy = false
  tags          = { Name = "stailab-${var.participant_name}" }
}

resource "aws_s3_bucket_versioning" "lab" {
  bucket = aws_s3_bucket.lab.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lab" {
  bucket = aws_s3_bucket.lab.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "lab" {
  bucket                  = aws_s3_bucket.lab.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Soft-delete equivalent: retain noncurrent object versions for 30 days
resource "aws_s3_bucket_lifecycle_configuration" "lab" {
  bucket     = aws_s3_bucket.lab.id
  depends_on = [aws_s3_bucket_versioning.lab]

  rule {
    id     = "soft-delete-30-days"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
