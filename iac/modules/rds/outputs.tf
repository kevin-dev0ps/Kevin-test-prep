output "endpoint" { value = aws_db_instance.this.address }
output "port" { value = aws_db_instance.this.port }
output "identifier" { value = aws_db_instance.this.identifier }
output "master_user_secret_arn" {
  description = "ARN of the RDS-managed master password secret (if managed)"
  value       = try(aws_db_instance.this.master_user_secret[0].secret_arn, null)
}
