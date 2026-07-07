# modules/cloudfront — distribution fronting the external ALB (mirrors "YEC Elevator App").
# viewer cert + web ACL must be us-east-1 ARNs (pass them in).
variable "project" { type = string }
variable "environment" { type = string }

variable "aliases" {
  description = "CNAMEs, e.g. [\"yomaelevator.com\"] (source). Clone may use its own domain."
  type        = list(string)
  default     = []
}
variable "origin_domain_name" {
  description = "External ALB DNS name (from the alb module)"
  type        = string
}
variable "acm_certificate_arn" {
  description = "us-east-1 ACM cert ARN for the aliases (empty = use default CF cert)"
  type        = string
  default     = ""
}
variable "web_acl_arn" {
  description = "us-east-1 WAFv2 WebACL ARN (from the waf module; empty = none)"
  type        = string
  default     = ""
}
variable "enable_host_check_function" {
  description = "Attach a viewer-request CF function (mirrors zyl-elevator-prod-host-check)"
  type        = bool
  default     = true
}
variable "tags" {
  type    = map(string)
  default = {}
}
