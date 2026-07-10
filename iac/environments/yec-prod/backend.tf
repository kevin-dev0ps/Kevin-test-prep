# Remote state for yec-elevator-prod (org production account).
# PREREQUISITE (one-time): create the bucket below IN the org-prod account with
# versioning enabled, then run: terraform init -reconfigure
#   aws s3api create-bucket --bucket elevator-yec-production-tfstate \
#     --region ap-southeast-1 \
#     --create-bucket-configuration LocationConstraint=ap-southeast-1 --profile <org-prod>
#   aws s3api put-bucket-versioning --bucket elevator-yec-production-tfstate \
#     --versioning-configuration Status=Enabled --profile <org-prod>
# No DynamoDB table needed — use_lockfile uses S3-native locking (Terraform >= 1.11).
terraform {
  backend "s3" {
    bucket       = "elevator-yec-production-tfstate"
    key          = "prod/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
    encrypt      = true
  }
}
