locals {
  name = "${var.project}-${var.environment}-waf"
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

resource "aws_wafv2_web_acl" "this" {
  name        = local.name
  description = "CloudFront WAF for ${var.project}-${var.environment}"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Optional geo allow-list (block anything not in the list)
  dynamic "rule" {
    for_each = length(var.allowed_countries) > 0 ? [1] : []
    content {
      name     = "geo-allow"
      priority = 0
      action {
        block {}
      }
      statement {
        not_statement {
          statement {
            geo_match_statement {
              country_codes = var.allowed_countries
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "geo-allow"
        sampled_requests_enabled   = true
      }
    }
  }

  # Rate limit
  rule {
    name     = "RateLimit"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit"
      sampled_requests_enabled   = true
    }
  }

  # AWS managed rule groups
  dynamic "rule" {
    for_each = { for i, g in var.managed_rule_groups : g => i }
    content {
      name     = rule.key
      priority = 10 + rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }

  tags = local.tags
}
