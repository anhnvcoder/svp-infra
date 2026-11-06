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
}
