# Naming: ${project}-${environment}-${component}
locals {
  name = "${var.project}-${var.environment}-${var.component}"
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    Component   = var.component
    ManagedBy   = "terraform"
  })
}

resource "aws_security_group" "task" {
  name        = "${local.name}-task"
  description = "${var.component} ECS task - ingress from ALB only"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${local.name}-task" })
}

resource "aws_security_group_rule" "from_alb" {
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.task.id
  source_security_group_id = var.alb_sg_id
  description              = "From ALB"
}

resource "aws_security_group_rule" "task_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.task.id
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name                   = var.component
    image                  = var.image
    essential              = true
    readonlyRootFilesystem = var.readonly_root_filesystem
    portMappings = [{
      containerPort = var.container_port
      hostPort      = var.container_port
      protocol      = "tcp"
      name          = "${var.component}-${var.container_port}-tcp"
    }]
    environment = [for k, v in var.environment_vars : { name = k, value = v }]
    secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = local.tags
}

resource "aws_ecs_service" "this" {
  name            = local.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = toset(var.target_group_arns)
    content {
      target_group_arn = load_balancer.value
      container_name   = var.component
      container_port   = var.container_port
    }
  }

  # Image tag is managed here, but ignore task-def revision churn from CI redeploys
  # if you later hand deploys to GitHub Actions (currently Terraform-managed).
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = local.tags
}

# ---- Autoscaling (CPU target tracking) ----
resource "aws_appautoscaling_target" "this" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${element(split("/", var.cluster_arn), 1)}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = var.cpu_target
  }
}
