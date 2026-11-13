# Long-lived resources of the env's account, made by the baseline root aws/accounts/<env> and kept through the destroy
# of a session: this root finds them by the names that root gives them, so the baseline is applied first. Each read
# below fails the plan, naming what is missing, when it is not. Design notes: README.md.

# Prometheus workspace svp-<env>: the workspace data source takes only an id, so the id is found by the exact alias
# among the workspaces whose alias starts with it.
data "aws_prometheus_workspaces" "env" {
  alias_prefix = local.name
}

locals {
  amp_workspace_id = one([for i, alias in data.aws_prometheus_workspaces.env.aliases : data.aws_prometheus_workspaces.env.workspace_ids[i] if alias == local.name])
}

data "aws_prometheus_workspace" "env" {
  workspace_id = local.amp_workspace_id

  lifecycle {
    precondition {
      condition     = local.amp_workspace_id != null
      error_message = "No Prometheus workspace with alias ${local.name} in the account: apply aws/accounts/${local.env} first."
    }
  }
}

data "aws_cloudwatch_log_group" "otel" {
  name = "/svp/${local.env}/otel"
}

data "aws_kms_alias" "observability" {
  name = "alias/${local.name}-observability"
}

# AMG has no lookup by name: the id comes from the learner (README.md), and the name check stops a workspace of
# another env or account from reaching the cluster values.
data "aws_grafana_workspace" "env" {
  workspace_id = var.grafana_workspace_id

  lifecycle {
    postcondition {
      condition     = self.name == local.name
      error_message = "grafana_workspace_id must be the id of the Grafana workspace ${local.name} of this account."
    }
  }
}

# Release repositories: every repository of the registry whose name starts with the path of a source repository
# (svp-backend/, svp-frontend/), so a service added to the registry module reaches the Kyverno role at the next apply.
# Repositories the pull through cache makes start with a cache prefix and are left out.
data "aws_ecr_repositories" "env" {}

data "aws_ecr_repository" "release" {
  for_each = toset([for n in data.aws_ecr_repositories.env.names : n if startswith(n, "svp-backend/") || startswith(n, "svp-frontend/")])

  name = each.key
}

# One read per cache rule of the registry module: a prefix whose rule is missing fails the plan.
data "aws_ecr_pull_through_cache_rule" "cache" {
  for_each = toset(["ghcr", "docker-hub", "quay", "k8s", "ecr-public"])

  ecr_repository_prefix = each.key
}

data "aws_kms_alias" "ecr" {
  name = "alias/${local.name}-ecr"
}
