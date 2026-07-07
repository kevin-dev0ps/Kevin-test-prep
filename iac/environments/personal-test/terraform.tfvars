# THROWAWAY test in your PERSONAL account. Local state. `destroy` when done.
aws_profile = "KMT-PERSONAL"            # <-- set your personal AWS CLI profile name
project     = "yec-elevator"
environment = "test"                # => yec-elevator-test-*  (clearly disposable)
region      = "ap-southeast-1"       # <-- change if your personal acct uses another region
sub_tag     = "Yoma Elevator"

vpc_cidr             = "10.70.0.0/16"
azs                  = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
public_subnet_cidrs  = ["10.70.1.0/24", "10.70.2.0/24", "10.70.3.0/24"]
private_subnet_cidrs = ["10.70.4.0/24", "10.70.5.0/24", "10.70.6.0/24"]
db_subnet_cidrs      = ["10.70.7.0/24", "10.70.8.0/24", "10.70.9.0/24"]

# desired_count=0 (set in main.tf) => images are never pulled; placeholder is fine.
be_image = "public.ecr.aws/nginx/nginx:latest"
fe_image = "public.ecr.aws/nginx/nginx:latest"
be_port  = 3001
fe_port  = 3000

# HTTP-only test: no ACM certs needed.
alb_certificate_arn        = ""
cloudfront_certificate_arn = ""
cloudfront_aliases         = []
waf_allowed_countries      = []

be_secrets = {}
fe_secrets = {}
