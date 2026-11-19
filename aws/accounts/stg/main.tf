locals {
  env = "stg"

  # The immutable OIDC sub prefix of each source repository: public GitHub ids that a rename or transfer keeps.
  github_backend  = "repo:anhnvcoder@96784839/svp-backend@1404091754"
  github_frontend = "repo:anhnvcoder@96784839/svp-frontend@1439816405"
  github_infra    = "repo:anhnvcoder@96784839/svp-infra@1440574580"

  ci_roles = {
    svp-ci-ecr-release-backend = {
      subject      = "${local.github_backend}:ref:refs/heads/main"
      repositories = ["svp-backend/*"]
      delete       = false
    }
    svp-ci-ecr-release-frontend = {
      subject      = "${local.github_frontend}:ref:refs/heads/main"
      repositories = ["svp-frontend/web"]
      delete       = false
    }
    svp-ci-ecr-rescan-backend = {
      subject      = "${local.github_backend}:environment:ecr-rescan"
      repositories = ["svp-backend/*"]
      delete       = true
    }
    svp-ci-ecr-rescan-frontend = {
      subject      = "${local.github_frontend}:environment:ecr-rescan"
      repositories = ["svp-frontend/web"]
      delete       = true
    }
  }

  amp_retention_days  = 31
  log_retention_days  = 7
  span_retention_days = 7
}

module "baseline" {
  source = "../../modules/account-baseline"

  env              = local.env
  account_id       = var.account_id
  region           = var.region
  zone_name        = var.zone_name
  budget_limit_usd = var.budget_limit_usd
  budget_emails    = var.budget_emails
}

# One file holds the cost flags of every account, so the roots that switch the same service cannot disagree.
# Design notes: aws/modules/paid-features/README.md.
module "paid_features" {
  source = "../../modules/paid-features"

  features = jsondecode(file("${path.root}/../../paid-features.json"))
}

module "registry" {
  source = "../../modules/registry"

  env               = local.env
  ci_roles          = local.ci_roles
  enhanced_scanning = module.paid_features.flags[local.env].inspector_ecr == "always"
}

# The role terraform plan assumes on the pull requests of svp-infra, approved in its environment terraform-plan.
module "ci_plan_role" {
  source = "../../modules/ci-plan-role"

  env               = local.env
  oidc_provider_arn = module.registry.github_oidc_provider_arn
  subject           = "${local.github_infra}:environment:terraform-plan"
  state_bucket      = module.baseline.state_bucket
  state_kms_key_arn = module.baseline.state_kms_key_arn
}

# Karpenter launches the Spot nodes of stg through CreateFleet, which needs this role to exist already: EC2 creates it
# on first use from the console only ("Service-linked role for Spot Instance requests", EC2 User Guide, read
# 2026-11-19), and the Karpenter controller may not create it. Design notes: aws/accounts/README.md.
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
}

module "observability" {
  source = "../../modules/observability"

  env                      = local.env
  amp_retention_days       = local.amp_retention_days
  log_retention_days       = local.log_retention_days
  span_retention_days      = local.span_retention_days
  platform_admin_group_id  = var.platform_admin_group_id
  platform_viewer_group_id = var.platform_viewer_group_id
  grafana_enabled = (
    module.paid_features.flags[local.env].managed_grafana == "always" ||
    (module.paid_features.flags[local.env].managed_grafana == "session" && var.session_open)
  )
}
