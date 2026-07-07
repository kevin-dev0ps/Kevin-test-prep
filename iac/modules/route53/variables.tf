# Module: route53 — inputs are environment-agnostic (no hardcoded names).
variable "project" {
  description = "Project slug, e.g. zyl-elevator"
  type        = string
}

variable "environment" {
  description = "Environment slug, e.g. dev | preprod | prod"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
