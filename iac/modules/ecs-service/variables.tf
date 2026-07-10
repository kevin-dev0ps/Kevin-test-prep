# modules/ecs-service — one Fargate service+task (be or fe). Instantiated per repo.
variable "project" {
  type    = string
}
variable "environment" { type = string }
variable "component"   { type = string }   # be | fe
variable "region"      { type = string }

variable "cluster_arn"        { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "alb_sg_id"          { type = string }   # SG allowed to reach the task
variable "target_group_arns" {
  description = "Target group ARNs this service registers into (one per ALB)"
  type        = list(string)
  default     = []
}

variable "image" {
  description = "Container image URI:tag (Terraform-managed per project decision)"
  type        = string
}
variable "container_port" {
  type    = number
  default = 3001
}
variable "cpu" {
  type    = number
  default = 1024
}
variable "memory" {
  type    = number
  default = 2048
}
variable "desired_count" {
  type    = number
  default = 1
}

variable "execution_role_arn" { type = string }
variable "task_role_arn"      { type = string }
variable "log_group_name"     { type = string }

variable "readonly_root_filesystem" {
  type    = bool
  default = false
}

variable "environment_vars" {
  description = "Plain (non-secret) env vars for the container"
  type        = map(string)
  default     = {}
}
variable "secrets" {
  description = "name -> Secrets Manager / SSM ARN, injected as container secrets"
  type        = map(string)
  default     = {}
}

variable "min_capacity" {
  type    = number
  default = 1
}
variable "max_capacity" {
  type    = number
  default = 4
}
variable "cpu_target" {
  type    = number
  default = 70
}

variable "tags" {
  type    = map(string)
  default = {}
}
