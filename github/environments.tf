################################################################################
# Environment promote of svp-backend and svp-frontend: it holds the GitHub App that writes to svp-gitops, so only
# jobs running on main may use it. The App's private key is a secret of this environment and stays out of Terraform:
# a secret in a resource would sit in clear in the state.
################################################################################

locals {
  # Repository => name of the variable that holds its App's client ID. The values stay in a map of their own: a
  # sensitive value inside a for_each argument would make Terraform refuse it.
  promote_environments = {
    svp-backend  = "SVP_GITOPS_APP_CLIENT_ID"
    svp-frontend = "SVP_WEB_APP_CLIENT_ID"
  }
  promote_app_client_ids = {
    svp-backend  = var.svp_gitops_app_client_id
    svp-frontend = var.svp_web_app_client_id
  }
}

resource "github_repository_environment" "promote" {
  for_each = local.promote_environments

  repository        = github_repository.this[each.key].name
  environment       = "promote"
  can_admins_bypass = true

  # Only branches matching the policies below (main alone) may deploy to this environment.
  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }

  # Destroying the environment deletes its secrets with it, the App's private key among them, which Terraform does not
  # hold: promote would stay broken until someone sets the key again by hand.
  lifecycle {
    prevent_destroy = true
  }
}

resource "github_repository_environment_deployment_policy" "promote_main" {
  for_each = local.promote_environments

  repository     = github_repository_environment.promote[each.key].repository
  environment    = github_repository_environment.promote[each.key].environment
  branch_pattern = "main"
}

resource "github_actions_environment_variable" "promote_app_client_id" {
  for_each = local.promote_environments

  repository    = github_repository_environment.promote[each.key].repository
  environment   = github_repository_environment.promote[each.key].environment
  variable_name = each.value
  value         = local.promote_app_client_ids[each.key]
}
