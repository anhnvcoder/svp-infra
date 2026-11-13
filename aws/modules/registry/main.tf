data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# Design notes: aws/modules/registry/README.md.
locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # The services of each source in files/sources.json of the svp-policy chart, named by their GHCR path without
  # ghcr.io/anhnvcoder/. A service added there needs its repository here, or its copy to ECR is denied.
  release_repositories = [
    "svp-backend/gateway",
    "svp-backend/user-service",
    "svp-backend/video-service",
    "svp-backend/engagement-service",
    "svp-backend/feed-service",
    "svp-backend/media-worker",
    "svp-frontend/web",
  ]
  release_groups        = distinct([for r in local.release_repositories : split("/", r)[0]])
  ci_repository_choices = concat(local.release_repositories, [for g in local.release_groups : "${g}/*"])

  # Prefix of the cached repositories => upstream registry, and whether the upstream needs a login.
  cache_rules = {
    ghcr         = { upstream = "ghcr.io", credential = true }
    "docker-hub" = { upstream = "registry-1.docker.io", credential = true }
    quay         = { upstream = "quay.io", credential = false }
    k8s          = { upstream = "registry.k8s.io", credential = false }
    "ecr-public" = { upstream = "public.ecr.aws", credential = false }
  }
  cache_credentials = toset([for prefix, rule in local.cache_rules : prefix if rule.credential])

  # Built from names rather than taken from the resources, so the policies are known at plan time.
  repository_arn_prefix = "arn:${data.aws_partition.current.partition}:ecr:${local.region}:${local.account_id}:repository"
  github_oidc_host      = "token.actions.githubusercontent.com"
  github_oidc_arn       = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:oidc-provider/${local.github_oidc_host}"
}
