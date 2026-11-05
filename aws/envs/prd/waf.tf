# Web ACL of AWS WAF in front of the CloudFront distribution of the media module: a rate limit per IP and AWS managed
# rule groups. A web ACL of scope CLOUDFRONT exists only in us-east-1, hence the provider of that region.
module "waf" {
  source = "../../modules/waf"

  providers = {
    aws = aws.us_east_1
  }

  name = "${local.name}-media"
}
