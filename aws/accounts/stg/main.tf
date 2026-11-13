locals {
  env = "stg"

  # The immutable OIDC sub prefix of each source repository: public GitHub ids that a rename or transfer keeps.
  github_backend  = "repo:anhnvcoder@96784839/svp-backend@1404091754"
  github_frontend = "repo:anhnvcoder@96784839/svp-frontend@1439816405"

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

module "registry" {
  source = "../../modules/registry"

  env      = local.env
  ci_roles = local.ci_roles
}

module "observability" {
  source = "../../modules/observability"

  env                      = local.env
  amp_retention_days       = local.amp_retention_days
  log_retention_days       = local.log_retention_days
  span_retention_days      = local.span_retention_days
  platform_admin_group_id  = var.platform_admin_group_id
  platform_viewer_group_id = var.platform_viewer_group_id
}
