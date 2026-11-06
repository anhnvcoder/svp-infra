# Who may read which entry: the plan's IAM policies and Pod Identity association against the map below, then one plan
# per validation rule with a value that only that rule rejects. The AWS provider is a mock: nothing reaches an account.
# The policies are asserted through the arguments of their aws_iam_policy_document data sources (the mock returns a
# fixed JSON). expected_entries restates the module's map on purpose: a change to who reads what must change both.

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
  env          = "stg"
  cluster_name = "svp-stg"

  expected_entries = {
    argocd   = ["argocd-notifications"]
    keda     = ["kafka-users"]
    svp      = ["glitchtip-runtime", "jwt-signing", "jwt-verify", "kafka-users", "pg-roles", "web"]
    svp-data = ["kafka-admin", "kafka-users", "pg-roles", "pg-superuser"]
    svp-obs  = ["glitchtip-runtime", "obs", "pg-roles"]
  }
}

run "stg" {
  command = plan

  # Entries: one per name any namespace reads, svp/<env>/<entry>, deleted at once on destroy.
  assert {
    condition     = toset([for s in aws_secretsmanager_secret.this : s.name]) == toset([for e in flatten(values(var.expected_entries)) : "svp/stg/${e}"])
    error_message = "The entries must be svp/stg/<entry> for exactly the entries of the map."
  }

  assert {
    condition     = alltrue([for s in aws_secretsmanager_secret.this : s.recovery_window_in_days == 0])
    error_message = "Every entry must have recovery_window_in_days = 0."
  }

  # Namespace roles: one per namespace, each reading exactly its own entries with GetSecretValue and nothing else.
  assert {
    condition     = toset(keys(aws_iam_role.namespace)) == toset(keys(var.expected_entries))
    error_message = "There must be one SecretStore role per namespace of the map."
  }

  assert {
    condition     = alltrue([for ns, r in aws_iam_role.namespace : r.name == "svp-stg-external-secrets-${ns}"])
    error_message = "The role of namespace <ns> must be svp-stg-external-secrets-<ns>."
  }

  assert {
    condition = alltrue([for ns, entries in var.expected_entries :
      length(data.aws_iam_policy_document.namespace[ns].statement) == 1 &&
      toset(data.aws_iam_policy_document.namespace[ns].statement[0].actions) == toset(["secretsmanager:GetSecretValue"]) &&
      toset(data.aws_iam_policy_document.namespace[ns].statement[0].resources) == toset([for e in entries : "arn:aws:secretsmanager:ap-southeast-1:111111111111:secret:svp/stg/${e}-??????"])
    ])
    error_message = "Each namespace role must allow only secretsmanager:GetSecretValue on exactly the entries of its namespace."
  }

  assert {
    condition = alltrue(flatten([for ns, d in data.aws_iam_policy_document.namespace : [
      for s in d.statement : [for r in s.resources : !strcontains(r, "*")]
    ]]))
    error_message = "No resource of a namespace policy may contain a *."
  }

  assert {
    condition = alltrue([for ns, d in data.aws_iam_policy_document.namespace_trust :
      length(d.statement) == 1 &&
      toset(d.statement[0].actions) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      length(d.statement[0].condition) == 0 &&
      length(d.statement[0].principals) == 1 &&
      one(d.statement[0].principals).type == "AWS" &&
      toset(one(d.statement[0].principals).identifiers) == toset(["arn:aws:iam::111111111111:role/svp-stg-external-secrets"])
    ]) && toset(keys(data.aws_iam_policy_document.namespace_trust)) == toset(keys(var.expected_entries))
    error_message = "Each namespace role must trust the controller role and nothing else."
  }

  # Controller role: only through EKS Pod Identity, for the controller's ServiceAccount of this cluster.
  assert {
    condition     = aws_iam_role.controller.name == "svp-stg-external-secrets"
    error_message = "The controller role must be svp-stg-external-secrets."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.controller_trust.statement) == 1 &&
      toset(data.aws_iam_policy_document.controller_trust.statement[0].actions) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      length(data.aws_iam_policy_document.controller_trust.statement[0].principals) == 1 &&
      one(data.aws_iam_policy_document.controller_trust.statement[0].principals).type == "Service" &&
      toset(one(data.aws_iam_policy_document.controller_trust.statement[0].principals).identifiers) == toset(["pods.eks.amazonaws.com"])
    )
    error_message = "The controller role must trust only the EKS Pod Identity service."
  }

  assert {
    condition = toset([for c in data.aws_iam_policy_document.controller_trust.statement[0].condition : "${c.test} ${c.variable} ${join(",", c.values)}"]) == toset([
      "StringEquals aws:RequestTag/eks-cluster-name svp-stg",
      "StringEquals aws:RequestTag/kubernetes-namespace external-secrets",
      "StringEquals aws:RequestTag/kubernetes-service-account external-secrets",
    ])
    error_message = "The controller trust must require the session tags of cluster svp-stg, namespace external-secrets and ServiceAccount external-secrets."
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.controller.cluster_name == "svp-stg" &&
      aws_eks_pod_identity_association.controller.namespace == "external-secrets" &&
      aws_eks_pod_identity_association.controller.service_account == "external-secrets"
    )
    error_message = "The Pod Identity association must be for external-secrets/external-secrets of cluster svp-stg."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.controller.statement) == 1 &&
      toset(data.aws_iam_policy_document.controller.statement[0].actions) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      toset(data.aws_iam_policy_document.controller.statement[0].resources) == toset([for ns in keys(var.expected_entries) : "arn:aws:iam::111111111111:role/svp-stg-external-secrets-${ns}"])
    )
    error_message = "The controller role may only assume the namespace roles."
  }
}

# The same module for prd: every name follows env, nothing else changes.
run "prd" {
  command = plan

  variables {
    env          = "prd"
    cluster_name = "svp-prd"
  }

  assert {
    condition     = toset([for s in aws_secretsmanager_secret.this : s.name]) == toset([for e in flatten(values(var.expected_entries)) : "svp/prd/${e}"])
    error_message = "The entries must be svp/prd/<entry>."
  }

  assert {
    condition     = alltrue([for s in aws_secretsmanager_secret.this : s.recovery_window_in_days == 0])
    error_message = "Every entry must have recovery_window_in_days = 0."
  }

  assert {
    condition = alltrue([for ns, entries in var.expected_entries :
      aws_iam_role.namespace[ns].name == "svp-prd-external-secrets-${ns}" &&
      toset(data.aws_iam_policy_document.namespace[ns].statement[0].resources) == toset([for e in entries : "arn:aws:secretsmanager:ap-southeast-1:111111111111:secret:svp/prd/${e}-??????"]) &&
      toset(one(data.aws_iam_policy_document.namespace_trust[ns].statement[0].principals).identifiers) == toset(["arn:aws:iam::111111111111:role/svp-prd-external-secrets"])
    ])
    error_message = "The prd namespace roles must read svp/prd/ entries and trust svp-prd-external-secrets."
  }

  assert {
    condition     = aws_eks_pod_identity_association.controller.cluster_name == "svp-prd" && contains([for c in data.aws_iam_policy_document.controller_trust.statement[0].condition : join(",", c.values)], "svp-prd")
    error_message = "The prd controller role must be bound to cluster svp-prd."
  }
}

run "env_unknown" {
  command = plan

  variables {
    env = "dev"
  }

  expect_failures = [var.env]
}

run "cluster_name_uppercase" {
  command = plan

  variables {
    cluster_name = "SVP-stg"
  }

  expect_failures = [var.cluster_name]
}
