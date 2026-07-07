locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# Matches source paths: /ecs/zyl-elevator-prod/be , /fe
resource "aws_cloudwatch_log_group" "ecs" {
  for_each          = toset(var.components)
  name              = "/ecs/${local.name_prefix}/${each.key}"
  retention_in_days = var.retention_in_days
  tags              = merge(local.tags, { Component = each.key })
}
