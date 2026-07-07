output "log_group_names" {
  value = { for k, g in aws_cloudwatch_log_group.ecs : k => g.name }
}
