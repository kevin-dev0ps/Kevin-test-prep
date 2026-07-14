output "instance_id" {
  description = "Bastion EC2 instance ID"
  value       = aws_instance.bastion.id
}

output "public_ip" {
  description = "Bastion public IP address (for SSH access)"
  value       = aws_instance.bastion.public_ip
}

output "private_ip" {
  description = "Bastion private IP address (internal VPC)"
  value       = aws_instance.bastion.private_ip
}

output "security_group_id" {
  description = "Bastion security group ID"
  value       = var.security_group_id
}

output "arn" {
  description = "Bastion instance ARN"
  value       = aws_instance.bastion.arn
}

output "availability_zone" {
  description = "Bastion availability zone"
  value       = aws_instance.bastion.availability_zone
}

output "vpc_security_group_ids" {
  description = "Security group IDs attached to bastion"
  value       = aws_instance.bastion.vpc_security_group_ids
}
