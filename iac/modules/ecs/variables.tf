# modules/ecs — the shared ECS (Fargate) cluster with Container Insights.
variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "container_insights" {
  type    = string
  default = "enabled"
}
variable "tags" {
  type    = map(string)
  default = {}
}
