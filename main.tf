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

locals {
  vpc_id    = length(var.vpc_id) > 0 ? var.vpc_id : data.aws_vpc.default.id
  subnet_id = length(var.subnet_id) > 0 ? var.subnet_id : sort(data.aws_subnet_ids.default.ids)[0]
  tf_tags = {
    terraform = true,
    by        = data.aws_caller_identity.aws.arn
  }
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
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*-${var.ubuntu_version}-amd64-sever-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

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
    cidr_blocks = ["${var.local_ip}/32", "${var.allowed_cidrs}"]
  }

  ingress {
    description = "Minecraft IP range"
    from_port   = 25565
    to_port     = 25565
    protocol    = "tcp"
    cidr_blocks = ["${var.allowed_cidrs}"]
  }

  egress_rules = ["all-all"]
  tags         = module.label.tags
}

resource "aws_key_pair" "local" {
  key_name   = "local"
  public_key = var.local_ssh_pub_key
}

# AWS Instance
resource "aws_instance" "minecraft_server" {
  ami               = "ami-839c94e3"
  instance_type     = var.instance_type
  availability_zone = var.region
  security_groups = [
    "${aws_security_group.minecraft.name}"
  ]
  tags = module.label.tags
}

# EBS Volume
resource "aws_ebs_volume" "data-vol" {
  availability_zone = "us-east-1"
  size              = 1
  tags = {
    Name = "data-volume"
  }
}

resource "aws_volume_attachment" "minecraft-vol" {
  device_name = "/dev/sdc"
  volume_id   = aws_ebs_volume.data-vol.id
  instance_id = aws_instance.minecraft_server.id
}
