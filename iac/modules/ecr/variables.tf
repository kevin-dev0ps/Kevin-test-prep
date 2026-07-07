# modules/ecr — one repository per application component (be, fe).
variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "components" {
  description = "Component names -> one ECR repo each (e.g. [\"be\",\"fe\"])"
  type        = list(string)
  default     = ["be", "fe"]
}
variable "image_tag_mutability" {
  type    = string
  default = "MUTABLE" # matches source
}
variable "scan_on_push" {
  type    = bool
  default = true # matches source
}
variable "max_image_count" {
  description = "Keep the newest N images (lifecycle policy)"
  type        = number
  default     = 20
}
variable "tags" {
  type    = map(string)
  default = {}
}
