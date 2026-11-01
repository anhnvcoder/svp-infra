################################################################################
# Rulesets. Required checks are accepted only from the GitHub Actions app (id 15368, gh api apps/github-actions), so a
# status of the same name posted by any other app or token does not satisfy them.
#
# Every main ruleset keeps history linear, and every pull_request rule allows squash alone, so a merge commit or a
# rebase stays blocked even if a repository's settings offer it again. No rule requires an approval: one person works
# the lab, and an author cannot approve their own pull request.
# strict_required_status_checks_policy stays false: true would make every pull request, the bots' own included, update
# its branch and rebuild its images after each merge, and the merge queue that avoids that exists only for repositories
# of an organization; the run on main after each merge catches what two pull requests break together.
# require_extra_approval_for_unattributed_changes (on by GitHub's default) is not exposed by the provider.
################################################################################

locals {
  github_actions_app_id = 15368
}

# svp-backend: every change to main through a pull request with ci-ok and images-ok green; no one bypasses.
resource "github_repository_ruleset" "backend_main" {
  repository  = github_repository.this["svp-backend"].name
  name        = "main"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }

    required_status_checks {
      strict_required_status_checks_policy = false
      do_not_enforce_on_create             = false

      required_check {
        context        = "ci-ok"
        integration_id = local.github_actions_app_id
      }
      required_check {
        context        = "images-ok"
        integration_id = local.github_actions_app_id
      }
    }
  }
}

# svp-backend owners: a change to a file with a code owner in CODEOWNERS (workflows, Renovate and scan rules,
# Makefile, deploy/ci/, the svp-policy chart) needs the owner's review, so a bot pull request on them never merges
# itself; files without an owner keep Renovate's auto-merge. The admin role may bypass it in pull requests only, and
# each bypass is recorded; main above still requires its checks.
resource "github_repository_ruleset" "backend_owners" {
  repository  = github_repository.this["svp-backend"].name
  name        = "owners"
  target      = "branch"
  enforcement = "active"

  bypass_actors {
    actor_id    = 5 # RepositoryRole admin
    actor_type  = "RepositoryRole"
    bypass_mode = "pull_request"
  }

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = true
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }
  }
}

# svp-frontend: same shape and checks as svp-backend.
resource "github_repository_ruleset" "frontend_main" {
  repository  = github_repository.this["svp-frontend"].name
  name        = "main"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }

    required_status_checks {
      strict_required_status_checks_policy = false
      do_not_enforce_on_create             = false

      required_check {
        context        = "ci-ok"
        integration_id = local.github_actions_app_id
      }
      required_check {
        context        = "images-ok"
        integration_id = local.github_actions_app_id
      }
    }
  }
}

# svp-frontend owners: a change to a file with a code owner in CODEOWNERS (workflows, Renovate and scan rules,
# Makefile) needs the owner's review, so a bot pull request on them never merges itself; files without an owner keep
# Renovate's auto-merge. The admin role may bypass it in pull requests only, and each bypass is recorded; main above
# still requires its checks.
resource "github_repository_ruleset" "frontend_owners" {
  repository  = github_repository.this["svp-frontend"].name
  name        = "owners"
  target      = "branch"
  enforcement = "active"

  bypass_actors {
    actor_id    = 5 # RepositoryRole admin
    actor_type  = "RepositoryRole"
    bypass_mode = "pull_request"
  }

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = true
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }
  }
}

# svp-gitops main: pull request and gitops-ok, no one bypasses. Together with owners below, a bot pull request that
# changes only envs/stg/ (no code owner) merges itself once gitops-ok is green.
resource "github_repository_ruleset" "gitops_main" {
  repository  = github_repository.this["svp-gitops"].name
  name        = "main"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }

    required_status_checks {
      strict_required_status_checks_policy = false
      do_not_enforce_on_create             = false

      required_check {
        context        = "gitops-ok"
        integration_id = local.github_actions_app_id
      }
    }
  }
}

# svp-gitops owners: a change to a file with a code owner (everything but envs/stg/) needs the owner's review. The
# admin role may bypass it in pull requests only, and each bypass is recorded; main above still requires gitops-ok.
resource "github_repository_ruleset" "gitops_owners" {
  repository  = github_repository.this["svp-gitops"].name
  name        = "owners"
  target      = "branch"
  enforcement = "active"

  bypass_actors {
    actor_id    = 5 # RepositoryRole admin
    actor_type  = "RepositoryRole"
    bypass_mode = "pull_request"
  }

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = true
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }
  }
}

# svp-gitops tags: no one but an admin creates, moves or deletes a tag (Argo CD follows commits, never tags).
resource "github_repository_ruleset" "gitops_tags" {
  repository  = github_repository.this["svp-gitops"].name
  name        = "tags"
  target      = "tag"
  enforcement = "active"

  bypass_actors {
    actor_id    = 5 # RepositoryRole admin
    actor_type  = "RepositoryRole"
    bypass_mode = "always"
  }

  conditions {
    ref_name {
      include = ["~ALL"]
      exclude = []
    }
  }

  rules {
    creation = true
    update   = true
    deletion = true
  }
}

# svp-infra main: pull request and infra-ok, no one bypasses. Created by Terraform. On a new account it is
# applied only after the first green run of check.yml on main (a required check that has never run would leave every
# pull request waiting).
resource "github_repository_ruleset" "infra_main" {
  repository  = github_repository.this["svp-infra"].name
  name        = "main"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }

    required_status_checks {
      strict_required_status_checks_policy = false
      do_not_enforce_on_create             = false

      required_check {
        context        = "infra-ok"
        integration_id = local.github_actions_app_id
      }
    }
  }
}

# svp-infra owners: a change to a file with a code owner in CODEOWNERS (workflows, Renovate and scan rules, Makefile,
# github/, aws/) needs the owner's review, so a bot pull request on them never merges itself; files without an owner
# keep Renovate's auto-merge. The admin role may bypass it in pull requests only, and each bypass is recorded; main
# above still requires its checks.
resource "github_repository_ruleset" "infra_owners" {
  repository  = github_repository.this["svp-infra"].name
  name        = "owners"
  target      = "branch"
  enforcement = "active"

  bypass_actors {
    actor_id    = 5 # RepositoryRole admin
    actor_type  = "RepositoryRole"
    bypass_mode = "pull_request"
  }

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = true
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }
  }
}

# svp-labs main: no deletion, no force push, every change through a pull request. No required check: the repository
# has no CI.
resource "github_repository_ruleset" "labs_main" {
  repository  = github_repository.this["svp-labs"].name
  name        = "main"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }
  }
}

# .github main: no deletion, no force push, every change through a pull request. No required check: the repository
# has no CI.
resource "github_repository_ruleset" "dotgithub_main" {
  repository  = github_repository.this[".github"].name
  name        = "main"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      allowed_merge_methods             = ["squash"]
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }
  }
}
