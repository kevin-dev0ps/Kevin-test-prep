# Naming: ${project}-${environment}-<component>   e.g. yec-elevator-prod-be
locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(var.components)
  name                 = "${local.name_prefix}-${each.key}"
  image_tag_mutability = var.image_tag_mutability
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
  tags = merge(local.tags, { Name = "${local.name_prefix}-${each.key}", Component = each.key })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the newest ${var.max_image_count} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.max_image_count
      }
      action = { type = "expire" }
    }]
  })
}
