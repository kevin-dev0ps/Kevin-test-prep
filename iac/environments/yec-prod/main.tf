# Environment: yec-prod  (project=yec-elevator, environment=prod) — the CLONE.
# `terraform apply` here CREATES fresh infra. Only terraform.tfvars differs per env.
locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    "Sub-Tag"   = var.sub_tag
  }
  components = ["be", "fe"]
}

module "vpc" {
  source               = "../../modules/vpc"
  project              = var.project
  environment          = var.environment
  region               = var.region
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs
  tags                 = local.tags
}

# ===================================================================
# Data source: Latest Amazon Linux 2 AMI
# ===================================================================
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ===================================================================
# Security Group: Bastion (SSH access)
# ===================================================================
resource "aws_security_group" "bastion" {
  name        = "${var.project}-${var.environment}-bastion"
  description = "Security group for bastion host (SSH jump host)"
  vpc_id      = module.vpc.vpc_id

  # Inbound SSH (restricted to specific IP or CIDR)
  # Default: Allow SSH from anywhere (0.0.0.0/0)
  # Change allowed_ssh_cidr in terraform.tfvars to restrict access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidr
    description = "SSH access to bastion"
  }

  # Outbound: All traffic allowed (for accessing RDS, internal services)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(
    local.tags,
    {
      Name = "${var.project}-${var.environment}-bastion-sg"
    }
  )
}

# ===================================================================
# Bastion EC2 Module
# ===================================================================
module "bastion" {
  source            = "../../modules/bastion"
  project           = var.project
  environment       = var.environment
  region            = var.region
  ami_id            = data.aws_ami.amazon_linux_2.id
  instance_type     = var.bastion_instance_type
  subnet_id         = module.vpc.public_subnet_ids[0]
  security_group_id = aws_security_group.bastion.id
  key_name          = var.bastion_key_name
  tags              = local.tags

  depends_on = [module.vpc]
}

#module "ecr" {
#  source      = "../../modules/ecr"
#  project     = var.project
#  environment = var.environment
#  region      = var.region
#  components  = local.components
#  tags        = local.tags
#}

module "cloudwatch" {
  source      = "../../modules/cloudwatch"
  project     = var.project
  environment = var.environment
  region      = var.region
  components  = local.components
  tags        = local.tags
}

module "s3_uploads" {
  source      = "../../modules/s3"
  project     = var.project
  environment = var.environment
  tags        = local.tags
}

module "iam" {
  source             = "../../modules/iam"
  project            = var.project
  environment        = var.environment
  region             = var.region
  components         = local.components
  attach_uploads_policy = true
  uploads_bucket_arn = module.s3_uploads.bucket_arn
  secret_arns        = local.app_secret_arns
  tags               = local.tags
}

module "alb" {
  source             = "../../modules/alb"
  project            = var.project
  environment        = var.environment
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = module.vpc.vpc_cidr
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
  enable_https         = var.enable_https
  certificate_arn      = var.alb_certificate_arn
  be_port              = var.be_port
  fe_port              = var.fe_port
  tags                 = local.tags
}

module "ecs" {
  source      = "../../modules/ecs"
  project     = var.project
  environment = var.environment
  region      = var.region
  tags        = local.tags
}

module "ecs_be" {
  source             = "../../modules/ecs-service"
  project            = var.project
  environment        = var.environment
  component          = "be"
  region             = var.region
  cluster_arn        = module.ecs.cluster_arn
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  alb_sg_id          = module.alb.alb_external_sg_id
  target_group_arns  = [module.alb.be_target_group_arn, module.alb.be_internal_target_group_arn]
  image              = var.be_image
  container_port     = var.be_port
  readonly_root_filesystem = true
  execution_role_arn = module.iam.task_execution_role_arn
  task_role_arn      = module.iam.task_role_arns["be"]
  log_group_name     = module.cloudwatch.log_group_names["be"]
  environment_vars   = local.be_env
  secrets            = local.be_secrets
  tags               = local.tags
}

module "ecs_fe" {
  source             = "../../modules/ecs-service"
  project            = var.project
  environment        = var.environment
  component          = "fe"
  region             = var.region
  cluster_arn        = module.ecs.cluster_arn
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  alb_sg_id          = module.alb.alb_external_sg_id
  target_group_arns  = [module.alb.fe_target_group_arn]
  image              = var.fe_image
  container_port     = var.fe_port
  cpu                = 512
  memory             = 1024
  execution_role_arn = module.iam.task_execution_role_arn
  task_role_arn      = module.iam.task_role_arns["fe"]
  log_group_name     = module.cloudwatch.log_group_names["fe"]
  environment_vars   = local.fe_env
  secrets            = local.fe_secrets
  tags               = local.tags
}

module "rds" {
  source                 = "../../modules/rds"
  project                = var.project
  environment            = var.environment
  region                 = var.region
  vpc_id                 = module.vpc.vpc_id
  db_subnet_ids          = module.vpc.db_subnet_ids
  app_security_group_ids = [module.ecs_be.task_sg_id, module.ecs_fe.task_sg_id]
  snapshot_identifier    = var.rds_snapshot_identifier
  tags                   = local.tags
}

# --- Edge (WAF + CloudFront). WAF + cert are us-east-1. ---
module "waf" {
  source            = "../../modules/waf"
  providers         = { aws = aws.us_east_1 }
  project           = var.project
  environment       = var.environment
  allowed_countries = var.waf_allowed_countries
  tags              = local.tags
}

module "cloudfront" {
  source                 = "../../modules/cloudfront"
  project                = var.project
  environment            = var.environment
  aliases                = var.cloudfront_aliases        # [] for now = default *.cloudfront.net domain
  origin_domain_name     = module.alb.external_dns_name
  origin_protocol_policy = "http-only"                   # ALB is HTTP-only during testing; switch to https-only after ALB cert
  acm_certificate_arn    = var.cloudfront_certificate_arn # "" for now = default CloudFront cert
  web_acl_arn            = module.waf.web_acl_arn
  tags                   = local.tags
}

output "cloudfront_domain" {
  description = "Test URL: https://<this>"
  value       = module.cloudfront.distribution_domain
}

output "alb_dns_name" {
  value = module.alb.external_dns_name
}

output "bastion_public_ip" {
  description = "Bastion public IP (for SSH access)"
  value       = module.bastion.public_ip
}

output "bastion_instance_id" {
  description = "Bastion instance ID"
  value       = module.bastion.instance_id
}
