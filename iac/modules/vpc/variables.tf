# modules/vpc — dedicated VPC with public / private / db tiers across AZs.
# Modelled on ZYL-Prod-VPC (172.25.0.0/16: 3 public, 3 private, 3 db subnets),
# but fully parameterized so the clone can use its own CIDR.

variable "project" {
  description = "Project slug, e.g. yec-elevator"
  type        = string
}

variable "environment" {
  description = "Environment slug: dev | preprod | prod"
  type        = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "172.25.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
}

variable "public_subnet_cidrs" {
  description = "One public subnet CIDR per AZ"
  type        = list(string)
  default     = ["172.25.1.0/24", "172.25.2.0/24", "172.25.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "One private (app) subnet CIDR per AZ"
  type        = list(string)
  default     = ["172.25.4.0/24", "172.25.5.0/24", "172.25.6.0/24"]
}

variable "db_subnet_cidrs" {
  description = "One database subnet CIDR per AZ"
  type        = list(string)
  default     = ["172.25.7.0/24", "172.25.8.0/24", "172.25.9.0/24"]
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway (cheaper) instead of one per AZ. Source uses 1."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
