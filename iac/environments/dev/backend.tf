# Remote state per environment. Create the bucket + lock table ONCE before init.
terraform {
  backend "s3" {
    bucket         = "zyl-elevator-tfstate" # TODO
    key            = "dev/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "zyl-elevator-tflock" # TODO
    encrypt        = true
  }
}
