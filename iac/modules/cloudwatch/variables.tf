# modules/cloudwatch — ECS log groups per component (matches /ecs/<prefix>/<component>).
variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "components" {
  type    = list(string)
  default = ["be", "fe"]
}
variable "retention_in_days" {
  type    = number
  default = 30
}
variable "tags" {
  type    = map(string)
  default = {}
}
