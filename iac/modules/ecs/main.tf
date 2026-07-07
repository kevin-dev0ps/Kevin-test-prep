locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-ecs"
  setting {
    name  = "containerInsights"
    value = var.container_insights
  }
  tags = merge(local.tags, { Name = "${local.name_prefix}-ecs" })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}
