# NEW production clone. `terraform apply` here CREATES fresh infra (deliberate).
aws_profile = "KEVIN-ZYL"
project     = "yec-elevator"
environment = "prod"
region      = "ap-southeast-1"
sub_tag     = "Yoma Elevator"
# => yec-elevator-prod-*, yec-elevator-prod-be-*, yec-elevator-prod-fe-*

# Dedicated VPC — 172.27.0.0/16 (separate from existing zyl-elevator 172.25.0.0/16).
vpc_cidr             = "172.27.0.0/16"
azs                  = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
public_subnet_cidrs  = ["172.27.1.0/24", "172.27.2.0/24", "172.27.3.0/24"]
private_subnet_cidrs = ["172.27.4.0/24", "172.27.5.0/24", "172.27.6.0/24"]
db_subnet_cidrs      = ["172.27.7.0/24", "172.27.8.0/24", "172.27.9.0/24"]

be_image = "REPLACE_WITH_BE_IMAGE_URI:tag"
fe_image = "REPLACE_WITH_FE_IMAGE_URI:tag"
be_port  = 3001
fe_port  = 3000

alb_certificate_arn        = "REPLACE_ap-southeast-1_ACM_ARN"
cloudfront_certificate_arn = "REPLACE_us-east-1_ACM_ARN"
cloudfront_aliases         = []
waf_allowed_countries      = []

be_secrets = {}
fe_secrets = {}
