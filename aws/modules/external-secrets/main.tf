data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# Design notes: aws/modules/external-secrets/README.md.
locals {
  # The remoteRef keys of the ExternalSecrets chart svp-cluster of the backend repository renders on eks: store aws,
  # managed object store, Kafka and Valkey outside the cluster, Argo CD notifications and Grafana Operator on. Entries
  # of in-cluster ones (s3-root, s3-users, pg-backup-s3, local-ca, local-tls) are not rendered then. A Secret added to
  # files/external-secrets.yaml of the chart needs its entry here too, or its ExternalSecret is denied.
  namespace_entries = {
    argocd   = ["argocd-notifications"]
    keda     = ["kafka-users"]
    svp      = ["glitchtip-runtime", "jwt-signing", "jwt-verify", "kafka-users", "pg-roles", "valkey-users", "web"]
    svp-data = ["kafka-admin", "pg-roles", "pg-superuser", "valkey-users"]
    svp-obs  = ["glitchtip-runtime", "grafana-operator", "kafka-users", "obs", "pg-roles"]
  }
  entries = toset(flatten(values(local.namespace_entries)))

  # The controller of External Secrets Operator (release external-secrets of svp-gitops, base/external-secrets.yaml).
  controller = {
    namespace       = "external-secrets"
    service_account = "external-secrets"
  }

  controller_role_name = "svp-${var.env}-external-secrets"
  # Built from names rather than taken from the resources, so the policies are known at plan time.
  iam_arn_prefix      = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role"
  controller_role_arn = "${local.iam_arn_prefix}/${local.controller_role_name}"
  namespace_role_arns = { for ns in keys(local.namespace_entries) : ns => "${local.iam_arn_prefix}/${local.controller_role_name}-${ns}" }

  # Secrets Manager appends a hyphen and six random characters to the name of a secret to make its ARN. "-??????"
  # matches exactly those six, so the pattern names one secret and no other whose name starts the same way.
  secret_arn_prefix = "arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret"
  secret_arns       = { for e in local.entries : e => "${local.secret_arn_prefix}:svp/${var.env}/${e}-??????" }
}

################################################################################
# Entries
################################################################################

# Only the entries. The values of kafka-admin, kafka-users and valkey-users are written write-only by the msk and
# elasticache modules in the same apply as the passwords they set; every other value by the learner's script after
# apply. None is in plan or state. Encrypted with the AWS managed key of Secrets Manager.
resource "aws_secretsmanager_secret" "this" {
  for_each = local.entries

  name        = "svp/${var.env}/${each.key}"
  description = "Source of External Secrets entry ${each.key} of env ${var.env}"
  # Deleted at once on destroy: each lab session builds the env again with the same names, which a secret waiting out a
  # recovery window would block. The values are written again in the next session.
  recovery_window_in_days = 0
}

################################################################################
# Controller role (EKS Pod Identity)
################################################################################

# The trust policy names the cluster, namespace and ServiceAccount through the session tags EKS Pod Identity sets, so
# an association of another cluster or another ServiceAccount cannot use the role even if someone creates one.
data "aws_iam_policy_document" "controller_trust" {
  statement {
    sid     = "AllowEksAuthToAssumeRoleForPodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-name"
      values   = [var.cluster_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.controller.namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.controller.service_account]
    }
  }
}

# The controller reads no entry itself: it only switches to the role of the SecretStore it serves. The session tags
# EKS Pod Identity sets are transitive, so that switch passes them on and needs sts:TagSession.
data "aws_iam_policy_document" "controller" {
  statement {
    sid       = "AssumeNamespaceRoles"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = values(local.namespace_role_arns)
  }
}

resource "aws_iam_role" "controller" {
  name               = local.controller_role_name
  description        = "External Secrets Operator of EKS cluster ${var.cluster_name}: assumes the role of each namespace's SecretStore"
  assume_role_policy = data.aws_iam_policy_document.controller_trust.json
}

resource "aws_iam_role_policy" "controller" {
  name   = "assume-namespace-roles"
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.controller.json
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = var.cluster_name
  namespace       = local.controller.namespace
  service_account = local.controller.service_account
  role_arn        = aws_iam_role.controller.arn
}

################################################################################
# Namespace roles (role of each SecretStore)
################################################################################

data "aws_iam_policy_document" "namespace_trust" {
  for_each = local.namespace_entries

  statement {
    sid     = "AllowExternalSecretsController"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = [local.controller_role_arn]
    }
  }
}

# GetSecretValue only: an ExternalSecret that reads a key of an entry makes no other call (DescribeSecret only with
# metadataPolicy Fetch, ListSecrets and BatchGetSecretValue only with dataFrom find, which the chart does not use).
data "aws_iam_policy_document" "namespace" {
  for_each = local.namespace_entries

  statement {
    sid       = "ReadNamespaceEntries"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for e in each.value : local.secret_arns[e]]
  }
}

resource "aws_iam_role" "namespace" {
  for_each = local.namespace_entries

  name               = "${local.controller_role_name}-${each.key}"
  description        = "SecretStore of namespace ${each.key} on EKS cluster ${var.cluster_name}: reads the entries of that namespace"
  assume_role_policy = data.aws_iam_policy_document.namespace_trust[each.key].json

  # IAM refuses a trust policy whose principal does not exist yet; the ARN is built from the name, so say the order.
  depends_on = [aws_iam_role.controller]
}

resource "aws_iam_role_policy" "namespace" {
  for_each = local.namespace_entries

  name   = "read-entries"
  role   = aws_iam_role.namespace[each.key].id
  policy = data.aws_iam_policy_document.namespace[each.key].json
}
