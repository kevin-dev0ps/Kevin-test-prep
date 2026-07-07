# modules/iam — ECS task-execution role, per-component task roles, and an
# optional GitHub Actions OIDC deploy role. Mirrors the source zyl-elevator-prod
# roles (be-task, fe-task, ecs-task-execution, github-actions).
variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }

variable "components" {
  type    = list(string)
  default = ["be", "fe"]
}

variable "secret_arns" {
  description = "Secrets Manager / SSM ARNs the tasks may read (empty = none yet)"
  type        = list(string)
  default     = []
}

variable "attach_uploads_policy" {
  description = "Attach the be->uploads S3 policy (known at plan time)"
  type        = bool
  default     = false
}

variable "uploads_bucket_arn" {
  description = "S3 bucket ARN the be task can read/write (uploads). Empty = skip."
  type        = string
  default     = ""
}

variable "github_oidc" {
  description = "Create a GitHub Actions OIDC deploy role"
  type        = bool
  default     = false
}
variable "github_oidc_provider_arn" {
  description = "arn:aws:iam::<acct>:oidc-provider/token.actions.githubusercontent.com"
  type        = string
  default     = ""
}
variable "github_repos" {
  description = "Allowed repos, e.g. [\"org/elevator-be-aws:*\",\"org/elevator-fe-aws:*\"]"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
