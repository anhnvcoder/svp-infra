################################################################################
# The repositories of the account listed in local.repositories (the lab repositories and .github, the default community
# health files of every repository); repository settings, Actions permissions, Dependabot alerts.
# Values started as what each repository ran when it was adopted (read with gh api GET); a change goes through a pull
# request here. Every repository merges by squash alone, the commit taking the pull request's title and body, so each
# commit on main is one pull request.
################################################################################

locals {
  repositories = {
    svp-backend = {
      description                 = "Mini short-video platform — DevOps + Solution Architect learning lab"
      has_wiki                    = false
      allow_merge_commit          = false
      allow_rebase_merge          = false
      allow_auto_merge            = true
      squash_merge_commit_title   = "PR_TITLE"
      squash_merge_commit_message = "PR_BODY"
      delete_branch_on_merge      = false
      vulnerability_alerts        = true
      allowed_actions             = "selected"
      sha_pinning_required        = true
      # The release jobs sign and attest images with cosign; scorecard.yml runs the OpenSSF Scorecard action.
      patterns_allowed = ["sigstore/cosign-installer@*", "ossf/scorecard-action@*"]
      # No workflow opens or approves a pull request with GITHUB_TOKEN: the promote pull requests use the App's token.
      can_approve_pull_request_reviews = false
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
      patterns_allowed                 = ["sigstore/cosign-installer@*", "ossf/scorecard-action@*"]
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
      patterns_allowed                 = ["ossf/scorecard-action@*"]
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
      # The two setup actions stay as GitHub held them when the repository was adopted, though check.yml uses neither
      # (the tools run from images pinned in the Makefile); scorecard.yml runs the OpenSSF Scorecard action.
      patterns_allowed = [
        "hashicorp/setup-terraform@*", "terraform-linters/setup-tflint@*", "ossf/scorecard-action@*",
      ]
      can_approve_pull_request_reviews = false
    }
    svp-labs = {
      description = "Learning labs of the short-video-platform: build-it-yourself versions compared with the industry-standard path"
      has_wiki    = true
      # Actions as in the repositories with CI: a public repository that runs any action would let a fork pull request or
      # a moved tag run foreign code. Dependabot alerts and auto-merge stay as GitHub left them: no dependency manifest,
      # no bot opens a pull request here.
      allow_merge_commit          = false
      allow_rebase_merge          = false
      allow_auto_merge            = false
      squash_merge_commit_title   = "PR_TITLE"
      squash_merge_commit_message = "PR_BODY"
      delete_branch_on_merge      = false
      vulnerability_alerts        = false
      allowed_actions             = "selected"
      sha_pinning_required        = true
      # The spike workflows install cosign.
      patterns_allowed                 = ["sigstore/cosign-installer@*"]
      can_approve_pull_request_reviews = false
    }
    # Default community health files (CONTRIBUTING.md, SECURITY.md, pull request template) that GitHub applies to every
    # repository of the account without its own copy; GitHub reads them only from a public repository named .github.
    ".github" = {
      description = "Quy ước chung và file cộng đồng mặc định cho mọi repo của anhnvcoder"
      has_wiki    = false
      # Actions as in svp-labs, with no action outside GitHub's own: the repository holds no workflow and no dependency
      # manifest.
      allow_merge_commit               = false
      allow_rebase_merge               = false
      allow_auto_merge                 = false
      squash_merge_commit_title        = "PR_TITLE"
      squash_merge_commit_message      = "PR_BODY"
      delete_branch_on_merge           = false
      vulnerability_alerts             = false
      allowed_actions                  = "selected"
      sha_pinning_required             = true
      patterns_allowed                 = []
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

# Read-only GITHUB_TOKEN by default; a workflow that needs more asks for it per job. No repository lets GITHUB_TOKEN
# create or approve pull requests.
resource "github_workflow_repository_permissions" "this" {
  for_each = local.repositories

  repository                       = github_repository.this[each.key].name
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = each.value.can_approve_pull_request_reviews
}
