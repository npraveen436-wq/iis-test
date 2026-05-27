# ==============================================================================
# IIS Test Setup - Simplified for learning
# Uses default VPC, no domain, public-internet software, AWS Secrets Manager
# ==============================================================================

# -----------------------------
# Lookup default VPC and subnets
# -----------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "selected" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

data "aws_caller_identity" "current" {}

# -----------------------------
# Latest Windows Server 2019 AMI (auto-fetched)
# -----------------------------
data "aws_ami" "windows_2019" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2019-English-Full-Base-*"]
  }
}

# -----------------------------
# IAM role for instances (so they can read Secrets Manager + use SSM)
# -----------------------------
resource "aws_iam_role" "test_server" {
  name = "iis-test-server-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.test_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "secrets" {
  name = "iis-test-secrets-read"
  role = aws_iam_role.test_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = "arn:aws:secretsmanager:us-east-1:${data.aws_caller_identity.current.account_id}:secret:dev/*"
    }]
  })
}

resource "aws_iam_instance_profile" "test_server" {
  name = "iis-test-server-profile"
  role = aws_iam_role.test_server.name
}

# -----------------------------
# Security group - HTTP + RDP from anywhere (TEST ONLY!)
# -----------------------------
resource "aws_security_group" "test_server" {
  name        = "iis-test-server-sg"
  description = "Test IIS server SG (open HTTP/RDP - test only)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "RDP from anywhere (test only - tighten in prod)"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "iis-test-server-sg" }
}

# -----------------------------
# Local: distribute servers across subnets
# -----------------------------
locals {
  subnet_ids = sort([for s in data.aws_subnet.selected : s.id])

  servers_with_subnet = {
    for idx, name in sort(keys(var.servers)) :
    name => {
      subnet_id = local.subnet_ids[idx % length(local.subnet_ids)]
      tags = {
        Name        = name
        Hostname    = name
        Environment = "test"
      }
    }
  }
}

# -----------------------------
# EC2 instances (one per entry in var.servers)
# -----------------------------
resource "aws_instance" "test_server" {
  for_each = local.servers_with_subnet

  ami                    = var.golden_ami_id != "" ? var.golden_ami_id : data.aws_ami.windows_2019.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = each.value.subnet_id
  vpc_security_group_ids = [aws_security_group.test_server.id]
  iam_instance_profile   = aws_iam_instance_profile.test_server.name

  associate_public_ip_address = true  # test only - so you can hit it from browser

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/setup.ps1.tftpl", {
    hostname    = each.key
    timezone    = var.timezone
    secret_id   = var.secret_id
    aws_region  = "us-east-1"
  })

  user_data_replace_on_change = true

  tags = each.value.tags

  lifecycle {
    ignore_changes = [ami]
  }
}
