variable "project" {
  type        = string
  description = "Project name (e.g., yec-elevator)"
}

variable "environment" {
  type        = string
  description = "Environment (prod, staging, test)"
}

variable "region" {
  type        = string
  description = "AWS region"
}

variable "instance_type" {
  type        = string
  default     = "t3.micro"
  description = "EC2 instance type for bastion"
}

variable "ami_id" {
  type        = string
  description = "AMI ID (Amazon Linux 2)"
}

variable "subnet_id" {
  type        = string
  description = "Public subnet ID where bastion runs"
}

variable "security_group_id" {
  type        = string
  description = "Security group ID for bastion (inbound SSH, outbound all)"
}

variable "key_name" {
  type        = string
  description = "EC2 key pair name for SSH access"
}

variable "associate_public_ip_address" {
  type        = bool
  default     = true
  description = "Assign public IP to bastion (should be true)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags to apply"
}
