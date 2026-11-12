# One AWS WAF web ACL per CloudFront distribution, each named after it: a rate limit per IP and AWS managed rule
# groups on all three, then what one surface alone needs. A web ACL of scope CLOUDFRONT exists only in us-east-1,
# hence the provider of that region.
locals {
  web_acls = {
    # Browsers post error reports to /monitoring with bodies above the 8 KB of SizeRestrictions_BODY. Bot Control only
    # labels bots until their share of the traffic is measured.
    web = {
      common_rule_set_count_overrides = ["SizeRestrictions_BODY"]
      bot_control                     = { inspection_level = "COMMON" }
      atp                             = null
    }
    # The gateway's login takes JSON and answers 200 or 401 (services/gateway/openapi.yaml of svp-backend).
    api = {
      common_rule_set_count_overrides = []
      bot_control                     = null
      atp = {
        login_path           = "/auth/login"
        payload_type         = "JSON"
        username_field       = "/email"
        password_field       = "/password"
        success_status_codes = [200]
        failure_status_codes = [401]
      }
    }
    media = {
      common_rule_set_count_overrides = []
      bot_control                     = null
      atp                             = null
    }
  }
}

module "waf" {
  source   = "../../modules/waf"
  for_each = local.web_acls

  providers = {
    aws = aws.us_east_1
  }

  name           = "${local.name}-${each.key}"
  log_bucket_arn = "arn:aws:s3:::${local.log_archive_buckets.waf}"

  common_rule_set_count_overrides = each.value.common_rule_set_count_overrides
  bot_control                     = each.value.bot_control
  atp                             = each.value.atp
}
