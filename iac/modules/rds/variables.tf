# modules/rds — single PostgreSQL instance (matches source zyl-elevator-prod-rds).
variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }

variable "db_subnet_ids" {
  description = "DB-tier subnet IDs (from the vpc module)"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC to create the DB security group in"
  type        = string
}

variable "app_security_group_ids" {
  description = "App/task SG ids allowed to reach Postgres on 5432"
  type        = list(string)
  default     = []
}

variable "snapshot_identifier" {
  description = "Restore from this snapshot id/ARN. Empty = fresh empty DB. When set, engine_version/db_name/username come from the snapshot."
  type        = string
  default     = ""
}

variable "engine_version" {
  type    = string
  default = "15.17"
}

variable "instance_class" {
  type    = string
  default = "db.t3.small"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "storage_type" {
  type    = string
  default = "gp2"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "db_name" {
  type    = string
  default = "yec_maintenance"
}

variable "username" {
  type    = string
  default = "yec_admin"
}

variable "backup_retention_period" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "kms_key_id" {
  description = "KMS key ARN for storage encryption. Empty = AWS-managed aws/rds key."
  type        = string
  default     = ""
}

variable "manage_master_user_password" {
  description = "Let RDS manage the master password in Secrets Manager"
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
