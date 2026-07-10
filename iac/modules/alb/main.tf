# Naming: ${project}-${environment}-*
locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# ---- Security groups ----
resource "aws_security_group" "alb_external" {
  name        = "${local.name_prefix}-alb-external"
  description = "Public ALB ingress"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${local.name_prefix}-alb-external" })
}

resource "aws_security_group_rule" "alb_ext_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_external.id
}
resource "aws_security_group_rule" "alb_ext_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_external.id
}
resource "aws_security_group_rule" "alb_ext_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_external.id
}

resource "aws_security_group" "alb_internal" {
  name        = "${local.name_prefix}-alb-internal"
  description = "Internal ALB ingress (from within VPC)"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${local.name_prefix}-alb-internal" })
}
resource "aws_security_group_rule" "alb_int_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.alb_internal.id
}
resource "aws_security_group_rule" "alb_int_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_internal.id
}

# ---- Load balancers ----
resource "aws_lb" "external" {
  name               = "${local.name_prefix}-alb-external"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_external.id]
  subnets            = var.public_subnet_ids
  enable_http2       = true
  tags               = merge(local.tags, { Name = "${local.name_prefix}-alb-external" })
}

resource "aws_lb" "internal" {
  name               = "${local.name_prefix}-alb-internal"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_internal.id]
  subnets            = var.private_subnet_ids
  enable_http2       = true
  tags               = merge(local.tags, { Name = "${local.name_prefix}-alb-internal" })
}

# ---- Target groups (target_type ip for Fargate) ----
resource "aws_lb_target_group" "be" {
  name        = "${local.name_prefix}-be-tg"
  port        = var.be_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id
  health_check {
    path                = var.be_health_path
    matcher             = "200-299"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
  tags = merge(local.tags, { Name = "${local.name_prefix}-be-tg", Component = "be" })
}

resource "aws_lb_target_group" "fe" {
  name        = "${local.name_prefix}-fe-tg"
  port        = var.fe_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id
  health_check {
    path                = var.fe_health_path
    matcher             = "200-299"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
  tags = merge(local.tags, { Name = "${local.name_prefix}-fe-tg", Component = "fe" })
}


# Dedicated target group for the internal ALB (a TG can attach to only one ALB).
resource "aws_lb_target_group" "be_internal" {
  name        = "${local.name_prefix}-be-int-tg"
  port        = var.be_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id
  health_check {
    path                = var.be_health_path
    matcher             = "200-299"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
  tags = merge(local.tags, { Name = "${local.name_prefix}-be-int-tg", Component = "be" })
}

# ---- Listeners (external) ----
# HTTP:80 -> redirect to 443 when HTTPS is on; otherwise forward to fe directly.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.external.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = var.enable_https ? "redirect" : "forward"
    target_group_arn = var.enable_https ? null : aws_lb_target_group.fe.arn
    dynamic "redirect" {
      for_each = var.enable_https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
  # Routing (rules + default action) is managed in the AWS console.
  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "https" {
  count             = var.enable_https ? 1 : 0
  load_balancer_arn = aws_lb.external.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.fe.arn
  }
  # Routing (rules + default action) is managed in the AWS console.
  lifecycle {
    ignore_changes = [default_action]
  }
}

# Listener rules (path routing + X-Origin-Verify enforcement + default 403) are
# managed in the AWS console — same ownership model as WAF/CloudFront. Terraform
# owns the ALB, target groups, and listener existence only; default_action is
# ignore_changes'd above so console-set routing does not drift.

# ---- Internal listener: 80 -> be ----
resource "aws_lb_listener" "internal_http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.be_internal.arn
  }
}
