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
  secret_arns        = concat(values(var.be_secrets), values(var.fe_secrets))
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
  certificate_arn    = var.alb_certificate_arn
  be_port            = var.be_port
  fe_port            = var.fe_port
  tags               = local.tags
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
  execution_role_arn = module.iam.task_execution_role_arn
  task_role_arn      = module.iam.task_role_arns["be"]
  log_group_name     = module.cloudwatch.log_group_names["be"]
  secrets            = var.be_secrets
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
  secrets            = var.fe_secrets
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

#module "cloudfront" {
#  source              = "../../modules/cloudfront"
#  project             = var.project
#  environment         = var.environment
#  aliases             = var.cloudfront_aliases
#  origin_domain_name  = module.alb.external_dns_name
#  acm_certificate_arn = var.cloudfront_certificate_arn
#  web_acl_arn         = module.waf.web_acl_arn
#  tags                = local.tags
#}
