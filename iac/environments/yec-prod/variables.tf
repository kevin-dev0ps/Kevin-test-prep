variable "aws_profile" { type = string }
variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "sub_tag" { type = string }

variable "rds_snapshot_identifier" {
  description = "Restore RDS from this snapshot (empty = fresh empty DB)"
  type        = string
  default     = ""
}

# Network (dedicated VPC for the clone — non-colliding with source 172.25.0.0/16)
variable "vpc_cidr" { type = string }
variable "azs" { type = list(string) }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "db_subnet_cidrs" { type = list(string) }

# App images (Terraform-managed per decision)
variable "be_image" { type = string }
variable "fe_image" { type = string }
variable "be_port" { type = number }
variable "fe_port" { type = number }

# Certificates (create/validate separately for the clone domain)
variable "alb_certificate_arn" { type = string }        # ap-southeast-1, for ALB 443
variable "cloudfront_certificate_arn" { type = string } # us-east-1, for CloudFront
variable "cloudfront_aliases" { type = list(string) }
variable "waf_allowed_countries" { type = list(string) }

# App secrets: name -> Secrets Manager/SSM ARN (values live outside Terraform)
variable "enable_https" {
  description = "Create HTTPS:443 listener on ALB (requires alb_certificate_arn)"
  type        = bool
  default     = false
}

variable "cloudfront_enabled" {
  description = "Enable CloudFront distribution (deferred until DNS ready)"
  type        = bool
  default     = false
}

variable "be_secrets" {
  type    = map(string)
  default = {}
}
variable "fe_secrets" {
  type    = map(string)
  default = {}
}
