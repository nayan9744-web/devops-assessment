data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name           = "${var.project}-${var.environment}"
  ecr_registry   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
  ecr_repository = "${local.ecr_registry}/${var.ecr_repository_name}"
}

# --- Network: the default VPC is sufficient for this task ---------------------------
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

# Latest Amazon Linux 2023 AMI, resolved through the public SSM parameter (no hardcoded AMI IDs).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "${local.name}: HTTP only. No SSH - administration happens through SSM Session Manager."
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${local.name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(var.allowed_http_cidrs)
  security_group_id = aws_security_group.app.id
  description       = "App HTTP"
  ip_protocol       = "tcp"
  from_port         = var.http_port
  to_port           = var.http_port
  cidr_ipv4         = each.value
}

# Egress is required for ECR pulls, CloudWatch Logs, SSM and OS updates (all HTTPS) and DNS.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs / package repos"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP for Amazon Linux package mirrors"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Logs --------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/${var.environment}/app"
  retention_in_days = var.log_retention_days
}

# --- Compute -----------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name
  monitoring             = var.detailed_monitoring

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region        = data.aws_region.current.region
    environment       = var.environment
    ecr_registry      = local.ecr_registry
    ecr_repository    = local.ecr_repository
    image_tag         = var.image_tag
    log_group         = aws_cloudwatch_log_group.app.name
    log_level         = var.log_level
    http_port         = var.http_port
    deploy_script_b64 = filebase64("${path.module}/../../scripts/deploy.sh")
  })

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers cannot reach instance credentials
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = local.name }

  lifecycle {
    ignore_changes = [ami] # don't replace the instance every time a new AMI is published
  }
}
