################################################################################
# The six repositories of the account: the five of the lab and .github (default community health files of every
# repository); repository settings, Actions permissions, Dependabot alerts.
# Every value is what the repository runs today (read with gh api GET); a change goes through a pull request here.
################################################################################

locals {
  repositories = {
    svp-backend = {
      description = "Mini short-video platform — DevOps + Solution Architect learning lab"
      has_wiki    = false
      # Merge commits and rebase stay allowed: the repository predates the squash-only rule of svp-frontend, svp-gitops
      # and svp-infra.
      allow_merge_commit          = true
      allow_rebase_merge          = true
      allow_auto_merge            = true
      squash_merge_commit_title   = "COMMIT_OR_PR_TITLE"
      squash_merge_commit_message = "COMMIT_MESSAGES"
      delete_branch_on_merge      = false
      vulnerability_alerts        = true
      allowed_actions             = "selected"
      sha_pinning_required        = true
      # The release jobs sign and attest images with cosign.
      patterns_allowed = ["sigstore/cosign-installer@*"]
      # "Allow GitHub Actions to create and approve pull requests" is on here alone; the ruleset requires no approval,
      # so it opens no extra path to merge.
      can_approve_pull_request_reviews = true
    }
    svp-frontend = {
      description                      = "Web client (Next.js + BFF) of the short-video platform lab"
      has_wiki                         = true
      allow_merge_commit               = false
      allow_rebase_merge               = false
      allow_auto_merge                 = true
      squash_merge_commit_title        = "PR_TITLE"
      squash_merge_commit_message      = "PR_BODY"
      delete_branch_on_merge           = false
      vulnerability_alerts             = true
      allowed_actions                  = "selected"
      sha_pinning_required             = true
      patterns_allowed                 = ["sigstore/cosign-installer@*"]
      can_approve_pull_request_reviews = false
    }
    svp-gitops = {
      description                      = "GitOps config (Helm values, env overlays, Argo CD apps) for short-video-platform; no secrets"
      has_wiki                         = true
      allow_merge_commit               = false
      allow_rebase_merge               = false
      allow_auto_merge                 = true
      squash_merge_commit_title        = "PR_TITLE"
      squash_merge_commit_message      = "PR_BODY"
      delete_branch_on_merge           = false
      vulnerability_alerts             = true
      allowed_actions                  = "selected"
      sha_pinning_required             = true
      patterns_allowed                 = []
      can_approve_pull_request_reviews = false
    }
    svp-infra = {
      description                 = "Terraform of the short-video-platform lab: AWS (stage 7), GCP, Cloudflare"
      has_wiki                    = true
      allow_merge_commit          = false
      allow_rebase_merge          = false
      allow_auto_merge            = true
      squash_merge_commit_title   = "PR_TITLE"
      squash_merge_commit_message = "PR_BODY"
      delete_branch_on_merge      = true
      vulnerability_alerts        = true
      allowed_actions             = "selected"
      sha_pinning_required        = true
      # As set on GitHub today; check.yml uses neither action (the tools run from images pinned in the Makefile).
      patterns_allowed                 = ["hashicorp/setup-terraform@*", "terraform-linters/setup-tflint@*"]
      can_approve_pull_request_reviews = false
    }
    svp-labs = {
      description = "Learning labs of the short-video-platform: build-it-yourself versions compared with the industry-standard path"
      has_wiki    = true
      # GitHub's defaults: the repository holds no workflow, release or deployment yet.
      allow_merge_commit               = true
      allow_rebase_merge               = true
      allow_auto_merge                 = false
      squash_merge_commit_title        = "COMMIT_OR_PR_TITLE"
      squash_merge_commit_message      = "COMMIT_MESSAGES"
      delete_branch_on_merge           = false
      vulnerability_alerts             = false
      allowed_actions                  = "all"
      sha_pinning_required             = false
      patterns_allowed                 = null
      can_approve_pull_request_reviews = false
    }
    # Default community health files (CONTRIBUTING.md, SECURITY.md, pull request template) that GitHub applies to every
    # repository of the account without its own copy; GitHub reads them only from a public repository named .github.
    ".github" = {
      description = "Quy ước chung và file cộng đồng mặc định cho mọi repo của anhnvcoder"
      has_wiki    = false
      # GitHub's defaults apart from the wiki: the repository holds no workflow and no dependency manifest.
      allow_merge_commit               = true
      allow_rebase_merge               = true
      allow_auto_merge                 = false
      squash_merge_commit_title        = "COMMIT_OR_PR_TITLE"
      squash_merge_commit_message      = "COMMIT_MESSAGES"
      delete_branch_on_merge           = false
      vulnerability_alerts             = false
      allowed_actions                  = "all"
      sha_pinning_required             = false
      patterns_allowed                 = null
      can_approve_pull_request_reviews = false
    }
  }
}

locals {
  vulnerability_alerts_on  = { for name, repo in local.repositories : name => repo if repo.vulnerability_alerts }
  vulnerability_alerts_off = { for name, repo in local.repositories : name => repo if !repo.vulnerability_alerts }
}

# Every repository is public on purpose: the lab is published, and rulesets on the Free plan need a public repository.
#trivy:ignore:GIT-0001
resource "github_repository" "this" {
  for_each = local.repositories

  name        = each.key
  description = each.value.description
  visibility  = "public"

  has_issues      = true
  has_projects    = true
  has_wiki        = each.value.has_wiki
  has_discussions = false
  is_template     = false

  allow_squash_merge          = true
  allow_merge_commit          = each.value.allow_merge_commit
  allow_rebase_merge          = each.value.allow_rebase_merge
  allow_auto_merge            = each.value.allow_auto_merge
  allow_update_branch         = false
  squash_merge_commit_title   = each.value.squash_merge_commit_title
  squash_merge_commit_message = each.value.squash_merge_commit_message
  merge_commit_title          = "MERGE_MESSAGE"
  merge_commit_message        = "PR_TITLE"
  delete_branch_on_merge      = each.value.delete_branch_on_merge
  web_commit_signoff_required = false

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }

  # Removing a repository from this file must never delete it: destroy archives it instead (the flag lives in state,
  # GitHub does not return it), and prevent_destroy stops any plan that would destroy one.
  archive_on_destroy = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "github_repository_vulnerability_alerts" "this" {
  for_each = local.vulnerability_alerts_on

  repository = github_repository.this[each.key].name
  enabled    = true
}

# The repositories with Dependabot alerts off (svp-labs and .github, as GitHub left them: no dependency manifest) sit
# apart, so the exception below cannot hide a repository of the resource above turning them off.
#trivy:ignore:GIT-0003
resource "github_repository_vulnerability_alerts" "off" {
  for_each = local.vulnerability_alerts_off

  repository = github_repository.this[each.key].name
  enabled    = false
}

resource "github_actions_repository_permissions" "this" {
  for_each = local.repositories

  repository           = github_repository.this[each.key].name
  enabled              = true
  allowed_actions      = each.value.allowed_actions
  sha_pinning_required = each.value.sha_pinning_required

  dynamic "allowed_actions_config" {
    for_each = each.value.allowed_actions == "selected" ? [each.value.patterns_allowed] : []
    content {
      github_owned_allowed = true
      verified_allowed     = false
      patterns_allowed     = allowed_actions_config.value
    }
  }

  # Destroy does not leave the setting as it is: the provider resets the repository to allow every action.
  lifecycle {
    prevent_destroy = true
  }
}

# Read-only GITHUB_TOKEN by default; a workflow that needs more asks for it per job.
resource "github_workflow_repository_permissions" "this" {
  for_each = local.repositories

  repository                       = github_repository.this[each.key].name
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = each.value.can_approve_pull_request_reviews
}
