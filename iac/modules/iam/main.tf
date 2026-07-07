# Naming: ${project}-${environment}-<role>
locals {
  name_prefix = "${var.project}-${var.environment}"
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---- Task EXECUTION role (pull image, write logs, read secrets at start) ----
resource "aws_iam_role" "task_execution" {
  name               = "${local.name_prefix}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "secrets_read" {
  count = length(var.secret_arns) > 0 ? 1 : 0
  statement {
    actions   = ["secretsmanager:GetSecretValue", "ssm:GetParameters", "ssm:GetParameter", "kms:Decrypt"]
    resources = var.secret_arns
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  count  = length(var.secret_arns) > 0 ? 1 : 0
  name   = "${local.name_prefix}-ecs-task-execution-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.secrets_read[0].json
}

# ---- Per-component TASK roles (app runtime permissions) ----
resource "aws_iam_role" "task" {
  for_each           = toset(var.components)
  name               = "${local.name_prefix}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = merge(local.tags, { Component = each.key })
}

# be task can access the uploads bucket (matches source be-s3-uploads policy)
data "aws_iam_policy_document" "uploads" {
  count = var.attach_uploads_policy ? 1 : 0
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [var.uploads_bucket_arn, "${var.uploads_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "be_uploads" {
  count  = var.attach_uploads_policy && contains(var.components, "be") ? 1 : 0
  name   = "${local.name_prefix}-be-s3-uploads"
  role   = aws_iam_role.task["be"].id
  policy = data.aws_iam_policy_document.uploads[0].json
}

# ---- GitHub Actions OIDC deploy role (optional) ----
data "aws_iam_policy_document" "github_assume" {
  count = var.github_oidc ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_repos
    }
  }
}

resource "aws_iam_role" "github_actions" {
  count              = var.github_oidc ? 1 : 0
  name               = "${local.name_prefix}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume[0].json
  tags               = local.tags
}
