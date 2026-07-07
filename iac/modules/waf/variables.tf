# modules/waf — WAFv2 WebACL for CloudFront (CLOUDFRONT scope => us-east-1).
# Mirrors zyl-elevator-prod-waf: managed rule sets + rate limit + optional geo allow.
# Instantiate with a us-east-1 provider:  providers = { aws = aws.us_east_1 }
variable "project" { type = string }
variable "environment" { type = string }

variable "rate_limit" {
  description = "Requests per 5-min per IP before blocking"
  type        = number
  default     = 300
}
variable "allowed_countries" {
  description = "ISO country codes to allow (empty = allow all). Source uses a whitelist."
  type        = list(string)
  default     = []
}
variable "managed_rule_groups" {
  type = list(string)
  default = [
    "AWSManagedRulesAmazonIpReputationList",
    "AWSManagedRulesCommonRuleSet",
    "AWSManagedRulesKnownBadInputsRuleSet",
    "AWSManagedRulesSQLiRuleSet",
  ]
}
variable "tags" {
  type    = map(string)
  default = {}
}
