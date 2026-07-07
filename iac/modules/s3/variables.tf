# modules/s3 — application uploads bucket (mirrors zyl-elevator-prod-uploads).
variable "project" { type = string }
variable "environment" { type = string }
variable "bucket_suffix" {
  type    = string
  default = "uploads"
}
variable "versioning" {
  type    = bool
  default = true
}
variable "tags" {
  type    = map(string)
  default = {}
}
