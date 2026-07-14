# modules/alb — external (public) + internal ALBs, their SGs, and be/fe target groups.
variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }

variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "vpc_cidr" { type = string }

variable "enable_https" {
  description = "Create the HTTPS:443 listener (needs certificate_arn). Off = HTTP-only (test)."
  type        = bool
  default     = true
}

variable "certificate_arn" {
  description = "ACM cert (ap-southeast-1) for the HTTPS:443 listener (required when enable_https)"
  type        = string
  default     = ""
}


variable "be_port" {
  type    = number
  default = 3001
}
variable "be_health_path" {
  type    = string
  default = "/api"
}
variable "fe_port" {
  type    = number
  default = 3000
}
variable "fe_health_path" {
  type    = string
  default = "/"
}

variable "tags" {
  type    = map(string)
  default = {}
}
