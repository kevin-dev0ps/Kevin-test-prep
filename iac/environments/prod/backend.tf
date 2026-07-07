terraform {
  backend "s3" {
    bucket         = "zyl-elevator-tfstate" # TODO
    key            = "prod/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "zyl-elevator-tflock" # TODO
    encrypt        = true
  }
}
