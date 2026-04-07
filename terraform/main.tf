provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  notify_param_arn = var.notify_config_parameter_name != "" ? "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.notify_config_parameter_name}" : ""
  subfinder_param_arn = var.subfinder_config_parameter_name != "" ? "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.subfinder_config_parameter_name}" : ""
  github_key_param_arn = var.github_deploy_key_parameter_name != "" ? "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.github_deploy_key_parameter_name}" : ""
  parameter_arns = compact([
    local.notify_param_arn,
    local.subfinder_param_arn,
    local.github_key_param_arn,
  ])
  scanner_env = var.enable_scanners ? "true" : "false"
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name_prefix}-ec2"
  public_key = var.ssh_public_key
}

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-sg"
  description = "SSH and outbound access for recon host"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "this" {
  name = "${var.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "ssm_read" {
  name = "${var.name_prefix}-ssm-read"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      length(local.parameter_arns) > 0 ? [
        {
          Effect = "Allow"
          Action = [
            "ssm:GetParameter",
            "ssm:GetParameters"
          ]
          Resource = local.parameter_arns
        }
      ] : [],
      [
        {
          Effect = "Allow"
          Action = ["kms:Decrypt"]
          Resource = "*"
          Condition = {
            StringEquals = {
              "kms:ViaService"   = "ssm.${var.aws_region}.amazonaws.com"
              "kms:CallerAccount" = data.aws_caller_identity.current.account_id
            }
          }
        }
      ]
    )
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name_prefix}-instance-profile"
  role = aws_iam_role.this.name
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.this.id]
  key_name                    = aws_key_pair.this.key_name
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = true
  user_data                   = templatefile("${path.module}/user_data.sh.tftpl", {
    repo_clone_url                  = var.repo_clone_url
    github_deploy_key_parameter     = var.github_deploy_key_parameter_name
    notify_config_parameter_name    = var.notify_config_parameter_name
    subfinder_config_parameter_name = var.subfinder_config_parameter_name
    enable_scanners                 = local.scanner_env
    name_prefix                     = var.name_prefix
  })

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.name_prefix}-ec2"
  }
}
