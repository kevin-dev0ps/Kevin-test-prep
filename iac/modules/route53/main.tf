# Module: route53
# Standard naming: ${var.project}-${var.environment}-<resource>
# e.g. name_prefix = "zyl-elevator-prod" or "zyl-elevator-dev"
locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# TODO (Phase 4): paste the refactored resources for "route53" here, taken from
# generated/terraformer/. Replace every hardcoded "zyl-elevator-prod" with
# "${local.name_prefix}". Do not put environment-specific values in this module.
