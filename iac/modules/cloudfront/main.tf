locals {
  name      = "${var.project}-${var.environment}"
  origin_id = "${local.name}-alb"
  use_acm   = var.acm_certificate_arn != "" && length(var.aliases) > 0
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# AWS-managed policies looked up by name (not brittle literal IDs).
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_function" "host_check" {
  count   = var.enable_host_check_function ? 1 : 0
  name    = "${local.name}-host-check"
  runtime = "cloudfront-js-2.0"
  comment = "Host header check"
  publish = true
  code    = <<-JS
    function handler(event) {
      return event.request;
    }
  JS
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "${var.project} ${var.environment} app"
  aliases         = var.aliases
  is_ipv6_enabled = true
  web_acl_id      = var.web_acl_arn != "" ? var.web_acl_arn : null

  origin {
    domain_name = var.origin_domain_name
    origin_id   = local.origin_id
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = var.origin_protocol_policy
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    # AWS managed "CachingDisabled" + "AllViewer" origin request policy
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_optimized.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    dynamic "function_association" {
      for_each = var.enable_host_check_function ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.host_check[0].arn
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.use_acm ? false : true
    acm_certificate_arn            = local.use_acm ? var.acm_certificate_arn : null
    ssl_support_method             = local.use_acm ? "sni-only" : null
    minimum_protocol_version       = local.use_acm ? "TLSv1.2_2021" : null
  }

  tags = local.tags
}
