# ===================================================================
# Bastion EC2 Instance
# Purpose: Jump host for SSH access to private resources (RDS, private EC2, etc)
# Network: Public subnet (receives public IP, reachable via SSH)
# Security: Restricted SSH inbound, all outbound allowed
# ===================================================================

resource "aws_instance" "bastion" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  key_name                    = var.key_name
  associate_public_ip_address = var.associate_public_ip_address

  # IMDSv2 enforcement: Require token to access instance metadata (security best practice)
  # IMDSv2 is more resistant to SSRF attacks
  metadata_options {
    http_endpoint           = "enabled"
    http_tokens             = "required"     # Force IMDSv2 (no IMDSv1)
    http_put_response_hop_limit = 1          # Only local requests can access metadata
  }

  # Root volume configuration
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20              # 20 GB root volume (sufficient for bastion)
    delete_on_termination = true
    encrypted             = true            # Encrypt at rest
  }

  # Monitoring enabled
  monitoring = true

  tags = merge(
    {
      Name        = "${var.project}-${var.environment}-bastion"
      Project     = var.project
      Environment = var.environment
      Role        = "bastion"
      ManagedBy   = "Terraform"
    },
    var.tags
  )

  lifecycle {
    ignore_changes = [ami]  # Allow AMI updates without recreating instance
  }
}

# CloudWatch alarm: Alert if bastion is unreachable
resource "aws_cloudwatch_metric_alarm" "bastion_status_check" {
  alarm_name          = "${var.project}-${var.environment}-bastion-status-check"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Alert if bastion instance status check fails"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.bastion.id
  }

  tags = {
    Name = "${var.project}-${var.environment}-bastion-alarm"
  }
}
