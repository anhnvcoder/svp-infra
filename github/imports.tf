################################################################################
# Adoption of what already exists on GitHub. The first plan reads each of these into state and must show no change of
# setting; once applied, the blocks are no-ops and may stay (an import block whose resource is already in state does
# nothing). A repository added to local.repositories is adopted the same way by the next plan. Ruleset main of
# svp-infra has no block: Terraform created it.
################################################################################

import {
  for_each = local.repositories
  to       = github_repository.this[each.key]
  id       = each.key
}

import {
  for_each = local.vulnerability_alerts_on
  to       = github_repository_vulnerability_alerts.this[each.key]
  id       = each.key
}

import {
  for_each = local.vulnerability_alerts_off
  to       = github_repository_vulnerability_alerts.off[each.key]
  id       = each.key
}

import {
  for_each = local.repositories
  to       = github_actions_repository_permissions.this[each.key]
  id       = each.key
}

import {
  for_each = local.repositories
  to       = github_workflow_repository_permissions.this[each.key]
  id       = each.key
}

# Ruleset ids are not secret (gh api repos/anhnvcoder/<repo>/rulesets -q '.[] | {id, name}'); id is <repo>:<ruleset id>.
import {
  to = github_repository_ruleset.backend_main
  id = "svp-backend:25522095"
}

import {
  to = github_repository_ruleset.frontend_main
  id = "svp-frontend:26234210"
}

import {
  to = github_repository_ruleset.gitops_main
  id = "svp-gitops:26133965"
}

import {
  to = github_repository_ruleset.gitops_owners
  id = "svp-gitops:26133969"
}

import {
  to = github_repository_ruleset.gitops_tags
  id = "svp-gitops:26133970"
}

import {
  for_each = local.promote_environments
  to       = github_repository_environment.promote[each.key]
  id       = "${each.key}:promote"
}

# Id is <repo>:<environment>:<policy id>
# (gh api repos/anhnvcoder/<repo>/environments/promote/deployment-branch-policies -q '.branch_policies[] | {id, name}').
import {
  for_each = {
    svp-backend  = 64799222
    svp-frontend = 64926180
  }
  to = github_repository_environment_deployment_policy.promote_main[each.key]
  id = "${each.key}:promote:${each.value}"
}

import {
  for_each = local.promote_environments
  to       = github_actions_environment_variable.promote_app_client_id[each.key]
  id       = "${each.key}:promote:${each.value}"
}
