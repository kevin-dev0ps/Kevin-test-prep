output "alb_external_sg_id" { value = aws_security_group.alb_external.id }
output "alb_internal_sg_id" { value = aws_security_group.alb_internal.id }
output "external_dns_name" { value = aws_lb.external.dns_name }
output "be_target_group_arn" { value = aws_lb_target_group.be.arn }
output "fe_target_group_arn" { value = aws_lb_target_group.fe.arn }

output "be_internal_target_group_arn" { value = aws_lb_target_group.be_internal.arn }
