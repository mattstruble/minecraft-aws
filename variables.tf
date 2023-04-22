variable "vpc_id" {
  description = "VPC for security group"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "VPC subnet id to place the instance"
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key name for provisioning"
  type        = string
  default     = ""
}

variable "bucket_name" {
  description = "Bucket name for persisting minecraft world"
  type        = string
  default     = ""
}

variable "bucket_force_destroy" {
  description = "Indicate whether all objects should be removed from the bucket"
  type        = bool
  default     = false
}

variable "bucket_object_versioning" {
  description = "Enable object versioning"
  type        = bool
  default     = true
}

# Tags
variable "name" {
  description = "Name to use for servers, tags, etc"
  type        = string
  default     = "minecraft"
}

variable "namespace" {
  description = "Namespace, eg an organization name or abberviation"
  type        = string
  default     = "games"
}

variable "environment" {
  description = "Environment, e.g. 'prod', 'staging', etc"
  type        = string
  default     = "games"
}

variable "tags" {
  description = "Extra tags to assign to objects"
  type        = map(any)
  default     = {}
}

# Instance
variable "associate_public_ip_address" {
  description = "Server has public IP by default"
  type        = bool
  default     = true
}

variable "ubuntu_version" {
  description = "Ubuntu server version - defaults to 20.04"
  type        = string
  default     = "20.04"
}

variable "ami" {
  description = "AMI to use for the instance - defaults to latest ubuntu"
  type        = string
  default     = ""
}

variable "ec2_instance_type" {
  description = "EC2 size to run the servers on"
  type        = string
  default     = "t2.micro"
}

variable "allowed_cidrs" {
  description = "Allowed CIDR blocks to the server - defaults to universe"
  type        = string
  default     = "0.0.0.0/0"
}

variable "region" {
  description = "AWS server location"
  type        = string
  default     = "us-east-1"
}

# Local
variable "local_ip" {
  description = "Local IP to enable for ssh access"
  type        = string
}

variable "local_ssh_pub_key" {
  description = "Local ssh public key"
  type        = string
}
