locals {
  env = "prd"
}

module "baseline" {
  source = "../../modules/account-baseline"

  env              = local.env
  account_id       = var.account_id
  region           = var.region
  zone_name        = var.zone_name
  budget_limit_usd = var.budget_limit_usd
  budget_emails    = var.budget_emails

  delegated_subdomains = var.delegated_subdomains

  dnssec_enabled    = true
  dnssec_signing    = var.dnssec_signing
  alarm_topic_arn   = module.alarms.topic_arn
  query_log_enabled = true
}

# Topic of the DNSSEC alarms. CloudWatch alarm actions reach a topic of their own region only, and the Route 53 metrics
# are in us-east-1; it lives as long as the zone, unlike the session topic of aws/envs/prd.
module "alarms" {
  source = "../../modules/alarms"

  name        = "svp-${local.env}-dns"
  region      = "us-east-1"
  alarm_email = var.alarm_email
}
