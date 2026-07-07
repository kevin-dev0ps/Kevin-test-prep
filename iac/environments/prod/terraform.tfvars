# EXISTING production — SOURCE of truth. Import into state, then `plan` must show
# NO changes. Never apply changes to this stack.
aws_profile = "KEVIN-ZYL"
project     = "zyl-elevator"
environment = "prod"
region      = "ap-southeast-1"
sub_tag     = "Yoma Elevator"
be_image    = "REPLACE_WITH_CURRENT_BE_IMAGE_URI:tag" # current live tag => clean plan
fe_image    = "REPLACE_WITH_CURRENT_FE_IMAGE_URI:tag"
# => zyl-elevator-prod-*, zyl-elevator-prod-be-*, zyl-elevator-prod-fe-*
