output "task_execution_role_arn" { value = aws_iam_role.task_execution.arn }
output "task_role_arns" {
  description = "component -> task role ARN"
  value       = { for k, r in aws_iam_role.task : k => r.arn }
}
output "github_actions_role_arn" {
  value = var.github_oidc ? aws_iam_role.github_actions[0].arn : null
}
