# Naming: ${project}-${environment}-rds
locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-rds"
  subnet_ids = var.db_subnet_ids
  tags       = merge(local.tags, { Name = "${local.name_prefix}-rds" })
}

resource "aws_db_parameter_group" "this" {
  name   = "${local.name_prefix}-rds"
  family = "postgres${split(".", var.engine_version)[0]}" # e.g. postgres15
  tags   = local.tags
}

resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-rds"
  description = "Postgres access for ${local.name_prefix}"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${local.name_prefix}-rds" })
}

resource "aws_security_group_rule" "db_ingress" {
  count                    = length(var.app_security_group_ids)
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = var.app_security_group_ids[count.index]
  description              = "Postgres from app task SG"
}

locals {
  # When set, restore the DB from this snapshot instead of creating an empty one.
  restoring = var.snapshot_identifier != ""
}

resource "aws_db_instance" "this" {
  identifier     = "${local.name_prefix}-rds"
  engine         = "postgres"
  instance_class = var.instance_class

  # --- restore vs fresh create ---
  # On restore, engine_version / storage / db_name / username come FROM the
  # snapshot, so they must be left null here or AWS rejects the request.
  snapshot_identifier = local.restoring ? var.snapshot_identifier : null
  engine_version      = local.restoring ? null : var.engine_version
  allocated_storage   = local.restoring ? null : var.allocated_storage
  db_name             = local.restoring ? null : var.db_name
  username            = local.restoring ? null : var.username

  storage_type      = var.storage_type
  storage_encrypted = true
  kms_key_id        = var.kms_key_id != "" ? var.kms_key_id : null

  # RDS manages the master password in Secrets Manager. On restore this RESETS
  # the (inherited) master user's password to a new managed secret.
  manage_master_user_password = var.manage_master_user_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  port                   = 5432

  multi_az                  = var.multi_az
  publicly_accessible       = false
  backup_retention_period   = var.backup_retention_period
  backup_window             = "02:00-03:00"
  maintenance_window        = "sun:04:00-sun:05:00"
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-rds-final"

  tags = merge(local.tags, { Name = "${local.name_prefix}-rds" })

  # snapshot_identifier is create-only; ignore so later plans don't force replace.
  lifecycle {
    ignore_changes = [snapshot_identifier, engine_version]
  }
}
