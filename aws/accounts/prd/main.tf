locals {
  env = "prd"
}

module "baseline" {
  source = "../../modules/account-baseline"

  env              = local.env
  account_id       = var.account_id
  region           = var.region
  lab_zone_name    = var.lab_zone_name
  budget_limit_usd = var.budget_limit_usd
  budget_emails    = var.budget_emails
}
