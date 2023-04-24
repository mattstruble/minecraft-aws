# Default network
provider "aws" {
  region = var.region
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = local.vpc_id
}

data "aws_caller_identity" "aws" {}

data "external" "current_ip" {
  program = ["bash", "-c", "curl -s 'https://api.ipify.org?format=json'"]
}


locals {
  vpc_id    = length(var.vpc_id) > 0 ? var.vpc_id : data.aws_vpc.default.id
  subnet_id = length(var.subnet_id) > 0 ? var.subnet_id : sort(data.aws_subnet_ids.default.ids)[0]
  tf_tags = {
    terraform = true,
    by        = data.aws_caller_identity.aws.arn
  }
}

data "aws_subnet" "selected" {
  id = local.subnet_id
}

# Keep labels, tags, etc consistent
module "label" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=master"

  namespace   = var.namespace
  stage       = var.environment
  name        = var.name
  delimiter   = "-"
  label_order = ["environment", "stage", "name", "attributes"]
  tags        = merge(var.tags, local.tf_tags)
}

# Find latest ubuntu AMI to use as default if none specified
#data "aws_ami" "ubuntu" {
#  most_recent = true
#
#  filter {
#    name   = "name"
#    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-${var.ubuntu_version}-amd64-sever-*"]
#  }
#
#  filter {
#    name   = "virtualization-type"
#    values = ["hvm"]
#  }
#}

# S3 bucket for data persistence
resource "random_string" "s3" {
  length  = 12
  special = false
  upper   = false
}

locals {
  use_existing_bucket = signum(length(var.bucket_name)) == 1
  bucket              = length(var.bucket_name) > 0 ? var.bucket_name : "${module.label.id}-${random_string.s3.result}"
}

module "s3" {
  source        = "terraform-aws-modules/s3-bucket/aws"
  create_bucket = local.use_existing_bucket ? false : true

  bucket = local.bucket
  acl    = "private"

  force_destroy = var.bucket_force_destroy

  versioning = {
    enabled = var.bucket_object_versioning
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  tags = module.label.tags
}

# S3 access
data "aws_iam_policy_document" "instance_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "allow_s3" {
  name               = "${module.label.id}-allow-ec2-to-s3"
  assume_role_policy = data.aws_iam_policy_document.instance_assume_role_policy.json
}

resource "aws_iam_instance_profile" "mc" {
  name = "${module.label.id}-instance-profile"
  role = aws_iam_role.allow_s3.id
}

data "aws_iam_policy_document" "s3_bucket_operations_policy" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.bucket}"]
  }

  statement {
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.bucket}/*"]
  }
}

resource "aws_iam_role_policy" "mc_ec2_to_s3" {
  name   = "${module.label.id}-allow-ec2-to-s3"
  role   = aws_iam_role.allow_s3.id
  policy = data.aws_iam_policy_document.s3_bucket_operations_policy.json
}

# Security group
resource "aws_security_group" "ec2_security_group" {
  name        = "${var.name}-ec2"
  description = "allow internal/local ssh and minecraft traffic"
  vpc_id      = local.vpc_id

  ingress {
    description = "Enable internal/local ssh access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${data.external.current_ip.result.ip}/32"]
  }

  ingress {
    description = "Minecraft IP range"
    from_port   = var.mc_port
    to_port     = var.mc_port
    protocol    = "tcp"
    cidr_blocks = ["${var.allowed_cidrs}"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = [var.allowed_cidrs]
  }
  tags = module.label.tags
}

# EC2 ssh key pair
resource "tls_private_key" "ec2_ssh" {
  count = length(var.key_name) > 0 ? 0 : 1

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2_ssh" {
  count = length(var.key_name) > 0 ? 0 : 1

  key_name   = "${var.name}-ec2-ssh-key"
  public_key = tls_private_key.ec2_ssh[0].public_key_openssh
}

locals {
  _ssh_key_name = length(var.key_name) > 0 ? var.key_name : aws_key_pair.ec2_ssh[0].key_name
}

# AWS Instance
resource "aws_instance" "ec2_minecraft" {

  key_name             = local._ssh_key_name
  ami                  = var.ami # != "" ? var.ami : data.aws_ami.ubuntu.image_id
  instance_type        = var.ec2_instance_type
  iam_instance_profile = aws_iam_instance_profile.mc.id

  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.ec2_security_group.id]
  associate_public_ip_address = var.associate_public_ip_address

  #availability_zone = data.aws_availability_zones.available.names[0]

  tags = module.label.tags
}

# EBS Volume
resource "aws_ebs_volume" "mc_vol" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = 8
  type              = "gp3"
  tags              = module.label.tags
}

resource "aws_volume_attachment" "mc_vol" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.mc_vol.id
  instance_id = aws_instance.ec2_minecraft.id
}

# CloudWatch Alarm
resource "aws_cloudwatch_metric_alarm" "active_connections" {
  alarm_name        = "${var.name}-network-alarm"
  alarm_description = "Detects when there hasn't been any inbound network traffic"

  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  period              = 300
  threshold           = 2500
  unit                = "Bytes"
  evaluation_periods  = 3
  namespace           = "AWS/EC2"
  metric_name         = "NetworkIn"
  alarm_actions       = ["arn:aws:automate:${var.region}:ec2:stop"]
  dimensions          = { InstanceId = aws_instance.ec2_minecraft.id }
}
