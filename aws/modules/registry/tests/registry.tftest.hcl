# What the registry of an env guarantees, for the CI roles of stg and prd, then one plan per validation rule with a
# value that only that rule rejects. The AWS provider is a mock: nothing reaches an account. Policies are asserted
# through the arguments of their aws_iam_policy_document data sources; the ARNs of the KMS key and the secrets are
# unknown in a plan, so their use is checked by type and name. Design notes: aws/modules/registry/README.md.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
      arn        = "arn:aws:iam::111111111111:user/test"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }
}

variables {
  env = "stg"

  # The CI roles of the two accounts, in the immutable sub form (owner and repository ids are made up).
  ci_roles = {
    svp-ci-ecr-release-backend = {
      subject      = "repo:anhnvcoder@1000001/svp-backend@2000001:ref:refs/heads/main"
      repositories = ["svp-backend/*"]
      delete       = false
    }
    svp-ci-ecr-release-frontend = {
      subject      = "repo:anhnvcoder@1000001/svp-frontend@2000002:ref:refs/heads/main"
      repositories = ["svp-frontend/web"]
      delete       = false
    }
    svp-ci-ecr-rescan-backend = {
      subject      = "repo:anhnvcoder@1000001/svp-backend@2000001:environment:ecr-rescan"
      repositories = ["svp-backend/*"]
      delete       = true
    }
    svp-ci-ecr-rescan-frontend = {
      subject      = "repo:anhnvcoder@1000001/svp-frontend@2000002:environment:ecr-rescan"
      repositories = ["svp-frontend/web"]
      delete       = true
    }
  }

  prd_ci_roles = {
    svp-ci-ecr-promote = {
      subject = "repo:anhnvcoder@1000001/svp-backend@2000001:environment:promote-prd"
      repositories = [
        "svp-backend/gateway", "svp-backend/user-service", "svp-backend/video-service", "svp-backend/engagement-service",
        "svp-backend/feed-service", "svp-backend/media-worker", "svp-frontend/web",
      ]
      delete = false
    }
    svp-ci-ecr-rescan-backend = {
      subject      = "repo:anhnvcoder@1000001/svp-backend@2000001:environment:ecr-rescan"
      repositories = ["svp-backend/*"]
      delete       = true
    }
    svp-ci-ecr-rescan-frontend = {
      subject      = "repo:anhnvcoder@1000001/svp-frontend@2000002:environment:ecr-rescan"
      repositories = ["svp-frontend/web"]
      delete       = true
    }
  }

  release_repositories = [
    "svp-backend/gateway", "svp-backend/user-service", "svp-backend/video-service", "svp-backend/engagement-service",
    "svp-backend/feed-service", "svp-backend/media-worker", "svp-frontend/web",
  ]

  cache_upstreams = {
    ghcr         = "ghcr.io"
    "docker-hub" = "registry-1.docker.io"
    quay         = "quay.io"
    k8s          = "registry.k8s.io"
    "ecr-public" = "public.ecr.aws"
  }

  push_actions = [
    "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload",
    "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:DescribeImages",
  ]

  repository_arn_prefix = "arn:aws:ecr:ap-southeast-1:111111111111:repository"
  github_oidc_arn       = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
}

run "stg" {
  command = plan

  # Release repositories: exactly the services of sources.json, immutable, encrypted with the env's key.
  assert {
    condition     = toset(keys(aws_ecr_repository.release)) == toset(var.release_repositories)
    error_message = "The release repositories must be exactly the services of sources.json under svp-backend/ and svp-frontend/."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.release : r.image_tag_mutability == "IMMUTABLE"])
    error_message = "Every release repository must have IMMUTABLE tags (ECR.2)."
  }

  assert {
    condition = alltrue([for r in aws_ecr_repository.release :
      length(r.encryption_configuration) == 1 && r.encryption_configuration[0].encryption_type == "KMS"
    ])
    error_message = "Every release repository must be encrypted with KMS (ECR.5)."
  }

  assert {
    condition     = aws_kms_key.ecr.enable_key_rotation && aws_kms_key.ecr.deletion_window_in_days == 30
    error_message = "The ECR key must rotate and wait 30 days before deletion."
  }

  assert {
    condition = alltrue(flatten([for s in data.aws_iam_policy_document.ecr_key.statement : [
      for p in s.principals : p.type == "AWS" && toset(p.identifiers) == toset(["arn:aws:iam::111111111111:root"])
    ]]))
    error_message = "Every principal of the ECR key policy must be the account itself, never \"*\" or another account."
  }

  # No lifecycle rule can reach a release or its referrers: the module declares no lifecycle policy of its own, and the
  # only lifecycle it sets is the one of the templates, which ECR applies to the cached repositories it creates only.
  assert {
    condition = alltrue([for f in fileset(path.module, "*.tf") :
      !strcontains(file("${path.module}/${f}"), "aws_ecr_lifecycle_policy")
    ])
    error_message = "No release repository may get a lifecycle policy: every release is untagged, so any rule selects releases."
  }

  assert {
    condition = alltrue([for t in aws_ecr_repository_creation_template.cache :
      toset(t.applied_for) == toset(["PULL_THROUGH_CACHE"]) && contains(keys(var.cache_upstreams), t.prefix)
    ]) && length(aws_ecr_repository_creation_template.cache) == 5
    error_message = "The creation templates must apply to the repositories of the five cache prefixes only (PULL_THROUGH_CACHE)."
  }

  # Pull through cache: five rules, a login for GHCR and Docker Hub only, a mutable expiring template per prefix.
  assert {
    condition     = { for k, r in aws_ecr_pull_through_cache_rule.this : k => r.upstream_registry_url } == var.cache_upstreams
    error_message = "The pull through cache rules must map ghcr, docker-hub, quay, k8s and ecr-public to their upstream registries."
  }

  assert {
    condition = alltrue([for k in ["quay", "k8s", "ecr-public"] : aws_ecr_pull_through_cache_rule.this[k].credential_arn == null]) && toset(
      [for s in aws_secretsmanager_secret.cache : s.name]
    ) == toset(["ecr-pullthroughcache/ghcr", "ecr-pullthroughcache/docker-hub"])
    error_message = "Only the ghcr and docker-hub rules must log in, with the secrets ecr-pullthroughcache/ghcr and ecr-pullthroughcache/docker-hub."
  }

  assert {
    condition     = alltrue([for s in aws_secretsmanager_secret.cache : s.kms_key_id == null])
    error_message = "The cache secrets must use the AWS managed key of Secrets Manager: ECR takes no customer managed key for them."
  }

  assert {
    condition = alltrue([for t in aws_ecr_repository_creation_template.cache :
      t.image_tag_mutability == "MUTABLE" && t.encryption_configuration[0].encryption_type == "KMS"
    ])
    error_message = "The cache templates must keep tags mutable and encrypt with KMS."
  }

  assert {
    condition = alltrue([for t in aws_ecr_repository_creation_template.cache : jsondecode(t.lifecycle_policy).rules == [{
      rulePriority = 1
      description  = "Expire cached images not pulled for 30 days"
      selection    = { tagStatus = "any", countType = "sinceImagePulled", countUnit = "days", countNumber = 30 }
      action       = { type = "expire" }
    }]])
    error_message = "The cache templates must expire only images not pulled for 30 days."
  }

  assert {
    condition = [for s in data.aws_iam_policy_document.template.statement : [s.sid, toset(s.actions), length(s.resources)]] == [
      ["CreateCachedRepositories", toset(["ecr:CreateRepository", "ecr:TagResource"]), 5],
      ["EncryptWithEcrKey", toset(["kms:CreateGrant", "kms:RetireGrant", "kms:DescribeKey"]), 1],
    ] && toset(data.aws_iam_policy_document.template.statement[0].resources) == toset([for p in keys(var.cache_upstreams) : "${var.repository_arn_prefix}/${p}/*"])
    error_message = "The template role may create repositories under the five cache prefixes and use one key only."
  }

  # Inspector: continuous enhanced scanning of the cached repositories, releases left out.
  assert {
    condition = (
      aws_ecr_registry_scanning_configuration.this.scan_type == "ENHANCED" &&
      length(aws_ecr_registry_scanning_configuration.this.rule) == 1 &&
      one(aws_ecr_registry_scanning_configuration.this.rule).scan_frequency == "CONTINUOUS_SCAN" &&
      toset([for f in one(aws_ecr_registry_scanning_configuration.this.rule).repository_filter : "${f.filter_type} ${f.filter}"]) ==
      toset([for p in keys(var.cache_upstreams) : "WILDCARD ${p}/*"])
    )
    error_message = "The registry must scan the five cache prefixes continuously with Inspector, and nothing else."
  }

  # CI roles: the OIDC provider, one exact claim per role, push rights on the role's own repositories.
  assert {
    condition     = aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com" && toset(aws_iam_openid_connect_provider.github.client_id_list) == toset(["sts.amazonaws.com"])
    error_message = "The OIDC provider must be GitHub Actions with the audience sts.amazonaws.com."
  }

  assert {
    condition     = toset(keys(aws_iam_role.ci)) == toset(keys(var.ci_roles)) && alltrue([for r in aws_iam_role.ci : r.max_session_duration == 3600])
    error_message = "There must be one role per entry of ci_roles, each with sessions of one hour."
  }

  # Each policy is named by a static key: an assertion over the whole map of data sources holds marked values, which
  # terraform test cannot print when the assertion fails.
  assert {
    condition = alltrue([for name, st in {
      svp-ci-ecr-release-backend  = data.aws_iam_policy_document.ci_trust["svp-ci-ecr-release-backend"].statement
      svp-ci-ecr-release-frontend = data.aws_iam_policy_document.ci_trust["svp-ci-ecr-release-frontend"].statement
      svp-ci-ecr-rescan-backend   = data.aws_iam_policy_document.ci_trust["svp-ci-ecr-rescan-backend"].statement
      svp-ci-ecr-rescan-frontend  = data.aws_iam_policy_document.ci_trust["svp-ci-ecr-rescan-frontend"].statement
      } :
      length(st) == 1 && toset(one(st).actions) == toset(["sts:AssumeRoleWithWebIdentity"]) &&
      one(one(st).principals).type == "Federated" &&
      toset(one(one(st).principals).identifiers) == toset([var.github_oidc_arn]) &&
      toset([for c in one(st).condition : jsonencode([c.test, c.variable, c.values])]) == toset([
        jsonencode(["StringEquals", "token.actions.githubusercontent.com:aud", ["sts.amazonaws.com"]]),
        jsonencode(["StringEquals", "token.actions.githubusercontent.com:sub", [var.ci_roles[name].subject]]),
      ])
    ])
    error_message = "Each CI role must trust the GitHub OIDC provider only, with StringEquals on aud sts.amazonaws.com and on exactly its one sub."
  }

  assert {
    condition = alltrue(flatten([for st in {
      svp-ci-ecr-release-backend  = data.aws_iam_policy_document.ci["svp-ci-ecr-release-backend"].statement
      svp-ci-ecr-release-frontend = data.aws_iam_policy_document.ci["svp-ci-ecr-release-frontend"].statement
      svp-ci-ecr-rescan-backend   = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-backend"].statement
      svp-ci-ecr-rescan-frontend  = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-frontend"].statement
      } : [
      for s in st : alltrue([for a in s.actions : !strcontains(a, "*")]) && (!contains(s.resources, "*") || toset(s.actions) == toset(["ecr:GetAuthorizationToken"]))
    ]]))
    error_message = "No CI policy may hold an action with a wildcard, and the resource \"*\" only with ecr:GetAuthorizationToken."
  }

  assert {
    condition = alltrue([for name, st in {
      svp-ci-ecr-release-backend  = data.aws_iam_policy_document.ci["svp-ci-ecr-release-backend"].statement
      svp-ci-ecr-release-frontend = data.aws_iam_policy_document.ci["svp-ci-ecr-release-frontend"].statement
      svp-ci-ecr-rescan-backend   = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-backend"].statement
      svp-ci-ecr-rescan-frontend  = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-frontend"].statement
      } :
      toset(flatten([for s in st : s.actions])) == toset(concat(
        ["ecr:GetAuthorizationToken"], var.push_actions, var.ci_roles[name].delete ? ["ecr:BatchDeleteImage"] : []
      ))
    ])
    error_message = "Each CI role must get exactly the ECR push actions, plus ecr:BatchDeleteImage only when its delete is true."
  }

  assert {
    condition = alltrue([for name, st in {
      svp-ci-ecr-release-backend  = data.aws_iam_policy_document.ci["svp-ci-ecr-release-backend"].statement
      svp-ci-ecr-release-frontend = data.aws_iam_policy_document.ci["svp-ci-ecr-release-frontend"].statement
      svp-ci-ecr-rescan-backend   = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-backend"].statement
      svp-ci-ecr-rescan-frontend  = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-frontend"].statement
      } : alltrue(flatten([for s in st : [
        for arn in s.resources : arn == "*" || startswith(arn, "${var.repository_arn_prefix}/${regex("^repo:[^/]+/([^@:]+)", var.ci_roles[name].subject)[0]}/")
    ]]))])
    error_message = "A CI role of stg may reach only the repositories of its own source repository: frontend never svp-backend/*, backend never svp-frontend/*."
  }

  assert {
    condition     = output.registry_host == "111111111111.dkr.ecr.ap-southeast-1.amazonaws.com" && toset(output.cache_prefixes) == toset(keys(var.cache_upstreams))
    error_message = "registry_host must be <account>.dkr.ecr.<region>.amazonaws.com and cache_prefixes the five rule prefixes."
  }
}

run "prd" {
  command = plan

  variables {
    env      = "prd"
    ci_roles = var.prd_ci_roles
  }

  assert {
    condition     = toset(keys(aws_ecr_repository.release)) == toset(var.release_repositories) && aws_iam_role.template.name == "svp-prd-ecr-template"
    error_message = "prd must have the same release repositories and its own template role svp-prd-ecr-template."
  }

  assert {
    condition = alltrue([for st in {
      svp-ci-ecr-promote         = data.aws_iam_policy_document.ci_trust["svp-ci-ecr-promote"].statement
      svp-ci-ecr-rescan-backend  = data.aws_iam_policy_document.ci_trust["svp-ci-ecr-rescan-backend"].statement
      svp-ci-ecr-rescan-frontend = data.aws_iam_policy_document.ci_trust["svp-ci-ecr-rescan-frontend"].statement
      } : alltrue([for c in one(st).condition :
        c.variable != "token.actions.githubusercontent.com:sub" || alltrue([for v in c.values : !endswith(v, ":ref:refs/heads/main")])
    ])])
    error_message = "No role of prd may trust a push to main: releases reach prd only through promote-prd."
  }

  assert {
    condition = alltrue([for name, st in {
      svp-ci-ecr-promote         = data.aws_iam_policy_document.ci_trust["svp-ci-ecr-promote"].statement
      svp-ci-ecr-rescan-backend  = data.aws_iam_policy_document.ci_trust["svp-ci-ecr-rescan-backend"].statement
      svp-ci-ecr-rescan-frontend = data.aws_iam_policy_document.ci_trust["svp-ci-ecr-rescan-frontend"].statement
      } :
      toset([for c in one(st).condition : jsonencode([c.test, c.variable, c.values])]) == toset([
        jsonencode(["StringEquals", "token.actions.githubusercontent.com:aud", ["sts.amazonaws.com"]]),
        jsonencode(["StringEquals", "token.actions.githubusercontent.com:sub", [var.prd_ci_roles[name].subject]]),
      ])
    ])
    error_message = "Each CI role of prd must trust exactly its one sub, with aud sts.amazonaws.com."
  }

  assert {
    condition = alltrue(flatten([for st in {
      svp-ci-ecr-promote         = data.aws_iam_policy_document.ci["svp-ci-ecr-promote"].statement
      svp-ci-ecr-rescan-backend  = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-backend"].statement
      svp-ci-ecr-rescan-frontend = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-frontend"].statement
      } : [
      for s in st : alltrue([for a in s.actions : !strcontains(a, "*")]) && (!contains(s.resources, "*") || toset(s.actions) == toset(["ecr:GetAuthorizationToken"]))
    ]]))
    error_message = "No CI policy of prd may hold an action with a wildcard, and the resource \"*\" only with ecr:GetAuthorizationToken."
  }

  assert {
    condition = alltrue([for name, st in {
      svp-ci-ecr-promote         = data.aws_iam_policy_document.ci["svp-ci-ecr-promote"].statement
      svp-ci-ecr-rescan-backend  = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-backend"].statement
      svp-ci-ecr-rescan-frontend = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-frontend"].statement
      } :
      toset(flatten([for s in st : s.actions])) == toset(concat(
        ["ecr:GetAuthorizationToken"], var.push_actions, var.prd_ci_roles[name].delete ? ["ecr:BatchDeleteImage"] : []
      ))
    ])
    error_message = "Each CI role of prd must get exactly the ECR push actions, plus ecr:BatchDeleteImage only when its delete is true."
  }

  # The promote role copies every release into prd; the rescan roles stay within their source repository.
  assert {
    condition = toset([for s in data.aws_iam_policy_document.ci["svp-ci-ecr-promote"].statement : s.resources if s.sid == "PushReleases"][0]) == toset([
      for r in var.release_repositories : "${var.repository_arn_prefix}/${r}"
    ])
    error_message = "svp-ci-ecr-promote must push to every release repository of prd."
  }

  assert {
    condition = alltrue([for name, st in {
      svp-ci-ecr-promote         = data.aws_iam_policy_document.ci["svp-ci-ecr-promote"].statement
      svp-ci-ecr-rescan-backend  = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-backend"].statement
      svp-ci-ecr-rescan-frontend = data.aws_iam_policy_document.ci["svp-ci-ecr-rescan-frontend"].statement
      } : name == "svp-ci-ecr-promote" || alltrue(flatten([for s in st : [
        for arn in s.resources : arn == "*" || startswith(arn, "${var.repository_arn_prefix}/${regex("^repo:[^/]+/([^@:]+)", var.prd_ci_roles[name].subject)[0]}/")
    ]]))])
    error_message = "A rescan role of prd may reach only the repositories of its own source repository."
  }
}

run "env_rejected" {
  command = plan

  variables {
    env = "dev"
  }

  expect_failures = [var.env]
}

run "role_name_rejected" {
  command = plan

  variables {
    ci_roles = {
      github-actions = { subject = "repo:anhnvcoder/svp-backend:ref:refs/heads/main", repositories = ["svp-backend/*"], delete = false }
    }
  }

  expect_failures = [var.ci_roles]
}

run "subject_wildcard_rejected" {
  command = plan

  variables {
    ci_roles = {
      svp-ci-ecr-release-backend = { subject = "repo:anhnvcoder/svp-backend:ref:refs/heads/*", repositories = ["svp-backend/*"], delete = false }
    }
  }

  expect_failures = [var.ci_roles]
}

run "subject_pull_request_rejected" {
  command = plan

  variables {
    ci_roles = {
      svp-ci-ecr-release-backend = { subject = "repo:anhnvcoder/svp-backend:pull_request", repositories = ["svp-backend/*"], delete = false }
    }
  }

  expect_failures = [var.ci_roles]
}

run "repositories_empty_rejected" {
  command = plan

  variables {
    ci_roles = {
      svp-ci-ecr-release-backend = { subject = "repo:anhnvcoder/svp-backend:ref:refs/heads/main", repositories = [], delete = false }
    }
  }

  expect_failures = [var.ci_roles]
}

run "repository_outside_releases_rejected" {
  command = plan

  variables {
    ci_roles = {
      svp-ci-ecr-release-backend = { subject = "repo:anhnvcoder/svp-backend:ref:refs/heads/main", repositories = ["ghcr/*"], delete = false }
    }
  }

  expect_failures = [var.ci_roles]
}

run "repository_duplicate_rejected" {
  command = plan

  variables {
    ci_roles = {
      svp-ci-ecr-release-frontend = {
        subject      = "repo:anhnvcoder/svp-frontend:ref:refs/heads/main"
        repositories = ["svp-frontend/web", "svp-frontend/web"]
        delete       = false
      }
    }
  }

  expect_failures = [var.ci_roles]
}
