# app-config.tf — BE env vars + secret refs. Terraform creates the param/secret
# CONTAINERS; real VALUES are set out of band (ignore_changes -> no drift).

variable "admin_email" {
  type    = string
  default = "ops@yomaelevator.com"
}
variable "frontend_origin" {
  type    = string
  default = "https://yomaelevator.com"
}

locals {
  param_prefix = "/${var.project}/${var.environment}"
  # RESTORE inherits the snapshot's DB name + master user (from zyl-elevator-prod).
  db_name     = "yecl_maintenance" # inherited from snapshot
  db_username = "zyl_admin"        # inherited from snapshot

  be_env = {
    DATABASE_SSL       = "true"
    S3_BUCKET          = module.s3_uploads.bucket_name
    AWS_REGION         = var.region
    PORT               = tostring(var.be_port)
    DB_SYNC            = "false"
    ADMIN_NAME         = "Operations Admin"
    DATABASE_SCHEMA    = "public"
    S3_PUBLIC_BASE_URL = ""
    JWT_EXPIRES_IN     = "8h"
    ADMIN_EMAIL        = var.admin_email
    FRONTEND_ORIGIN    = var.frontend_origin
  }

  be_secrets = {
    ADMIN_JWT_SECRET  = aws_ssm_parameter.jwt_secret.arn
    ADMIN_PASSWORD    = aws_ssm_parameter.admin_password.arn
    DATABASE_HOST     = aws_ssm_parameter.rds_endpoint.arn
    DATABASE_NAME     = aws_ssm_parameter.rds_database_name.arn
    DATABASE_PASSWORD = aws_ssm_parameter.rds_password.arn
    DATABASE_PORT     = aws_ssm_parameter.rds_port.arn
    DATABASE_USER     = aws_ssm_parameter.rds_username.arn
    AZURE_CLIENT_ID   = "${aws_secretsmanager_secret.sso.arn}:AZURE_CLIENT_ID::"
    AZURE_TENANT_ID   = "${aws_secretsmanager_secret.sso.arn}:AZURE_TENANT_ID::"
  }

  # FE — non-sensitive config in code; Azure/auth secrets out of band.
  fe_env = {
    API_BASE_URL = "https://d23jjsj6ilqrhj.cloudfront.net" # switch to real domain at cutover
  }
  fe_secrets = {
    AUTH_MICROSOFT_ENTRA_ID_ID     = "${aws_secretsmanager_secret.fe_sso.arn}:AUTH_MICROSOFT_ENTRA_ID_ID::"
    AUTH_MICROSOFT_ENTRA_ID_ISSUER = "${aws_secretsmanager_secret.fe_sso.arn}:AUTH_MICROSOFT_ENTRA_ID_ISSUER::"
    AUTH_MICROSOFT_ENTRA_ID_SECRET = "${aws_secretsmanager_secret.fe_sso.arn}:AUTH_MICROSOFT_ENTRA_ID_SECRET::"
    AUTH_SECRET                    = "${aws_secretsmanager_secret.fe_sso.arn}:AUTH_SECRET::"
  }

  # ARNs the task-execution role may read (BE + FE).
  app_secret_arns = [
    aws_ssm_parameter.jwt_secret.arn,
    aws_ssm_parameter.admin_password.arn,
    aws_ssm_parameter.rds_endpoint.arn,
    aws_ssm_parameter.rds_database_name.arn,
    aws_ssm_parameter.rds_password.arn,
    aws_ssm_parameter.rds_port.arn,
    aws_ssm_parameter.rds_username.arn,
    aws_secretsmanager_secret.sso.arn,
    aws_secretsmanager_secret.fe_sso.arn,
  ]
}

# From infra outputs (safe to manage in TF)
resource "aws_ssm_parameter" "rds_endpoint" {
  name  = "${local.param_prefix}/rds/endpoint"
  type  = "String"
  value = module.rds.endpoint
  tags  = local.tags
}
resource "aws_ssm_parameter" "rds_port" {
  name  = "${local.param_prefix}/rds/port"
  type  = "String"
  value = "5432"
  tags  = local.tags
}
resource "aws_ssm_parameter" "rds_database_name" {
  name  = "${local.param_prefix}/rds/database-name"
  type  = "String"
  value = local.db_name
  tags  = local.tags
}
resource "aws_ssm_parameter" "rds_username" {
  name  = "${local.param_prefix}/rds/username"
  type  = "String"
  value = local.db_username
  tags  = local.tags
}

# Secret values set OUT OF BAND (placeholder + ignore_changes)
resource "aws_ssm_parameter" "rds_password" {
  name  = "${local.param_prefix}/rds/password"
  type  = "SecureString"
  value = "SET_OUT_OF_BAND" # must equal the RDS master password
  tags  = local.tags
  lifecycle {
    ignore_changes = [value]
  }
}
resource "aws_ssm_parameter" "jwt_secret" {
  name  = "${local.param_prefix}/app/jwt-secret"
  type  = "SecureString"
  value = "SET_OUT_OF_BAND"
  tags  = local.tags
  lifecycle {
    ignore_changes = [value]
  }
}
resource "aws_ssm_parameter" "admin_password" {
  name  = "${local.param_prefix}/app/admin-password"
  type  = "SecureString"
  value = "SET_OUT_OF_BAND"
  tags  = local.tags
  lifecycle {
    ignore_changes = [value]
  }
}
resource "aws_secretsmanager_secret" "sso" {
  name = "${var.project}-be-sso-key"
  tags = local.tags
}
resource "aws_secretsmanager_secret_version" "sso" {
  secret_id     = aws_secretsmanager_secret.sso.id
  secret_string = jsonencode({ AZURE_CLIENT_ID = "SET_OUT_OF_BAND", AZURE_TENANT_ID = "SET_OUT_OF_BAND" })
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# FE SSO/auth secret — clone-owned (NOT the live elevator-fe-sso-key). Values out of band.
resource "aws_secretsmanager_secret" "fe_sso" {
  name = "${var.project}-fe-sso-key" # => elevator-yec-fe-sso-key
  tags = local.tags
}
resource "aws_secretsmanager_secret_version" "fe_sso" {
  secret_id = aws_secretsmanager_secret.fe_sso.id
  secret_string = jsonencode({
    AUTH_MICROSOFT_ENTRA_ID_ID     = "SET_OUT_OF_BAND"
    AUTH_MICROSOFT_ENTRA_ID_ISSUER = "SET_OUT_OF_BAND"
    AUTH_MICROSOFT_ENTRA_ID_SECRET = "SET_OUT_OF_BAND"
    AUTH_SECRET                    = "SET_OUT_OF_BAND"
  })
  lifecycle {
    ignore_changes = [secret_string]
  }
}
