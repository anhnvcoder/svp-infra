# One role per platform controller, assumed through EKS Pod Identity. The trust policy names the cluster, namespace
# and ServiceAccount through the session tags EKS Pod Identity sets, so an association of another cluster or of
# another ServiceAccount cannot use the role even if someone creates one.
data "aws_iam_policy_document" "pod_identity_trust" {
  for_each = local.pod_identity

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
      values   = [var.name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [each.value.namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account]
    }
  }
}

################################################################################
# AWS Load Balancer Controller
################################################################################

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${var.name}-aws-load-balancer-controller"
  description        = "AWS Load Balancer Controller of EKS cluster ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust["aws_load_balancer_controller"].json
}

# The policy the project publishes for this exact controller release (docs/install/iam_policy.json at tag v3.6.2),
# kept as it is. The chart version that installs the controller must match: upgrading the controller means replacing
# this file with the policy of the new tag in the same change.
resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "${var.name}-aws-load-balancer-controller"
  description = "IAM policy of AWS Load Balancer Controller v3.6.2 for EKS cluster ${var.name}"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-v3.6.2.json")
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

################################################################################
# EBS CSI driver
################################################################################

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi-driver"
  description        = "EBS CSI driver controller of EKS cluster ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust["ebs_csi"].json
}

# The AWS managed policy of the driver: create, attach, resize and delete volumes and their snapshots, and tag them.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

################################################################################
# Telemetry, alert rules, image verification and canary analysis
################################################################################

locals {
  # Roles of local.pod_identity whose permissions are an inline policy of this module, by the same key; the role is
  # named <name>-<role>.
  pod_identity_roles = {
    otel_collector        = { role = "otel-collector", description = "OpenTelemetry Collector", policy = data.aws_iam_policy_document.otel_collector.json }
    prometheus_agent      = { role = "prometheus-agent", description = "Prometheus agent", policy = data.aws_iam_policy_document.prometheus_agent.json }
    ack_prometheusservice = { role = "ack-prometheusservice", description = "ACK prometheusservice controller", policy = data.aws_iam_policy_document.ack_prometheusservice.json }
    kyverno_admission     = { role = "kyverno-admission", description = "Kyverno admission controller", policy = data.aws_iam_policy_document.kyverno_admission.json }
    argo_rollouts         = { role = "argo-rollouts", description = "Argo Rollouts controller", policy = data.aws_iam_policy_document.argo_rollouts.json }
  }

  rule_groups_namespaces_arn = "${replace(var.amp_workspace_arn, ":workspace/", ":rulegroupsnamespace/")}/*"
}

data "aws_iam_policy_document" "otel_collector" {
  statement {
    sid       = "WriteMetrics"
    actions   = ["aps:RemoteWrite"]
    resources = [var.amp_workspace_arn]
  }

  # The log stream the observability module creates; the OTLP endpoint of CloudWatch Logs writes to an existing one.
  statement {
    sid       = "WriteLogs"
    actions   = ["logs:PutLogEvents"]
    resources = ["${var.log_group_arn}:log-stream:otel-collector"]
  }

  statement {
    sid       = "UseLogGroupKeyThroughLogs"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.observability_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  # Resource * because the action has no resource type (Service Authorization Reference, AWS X-Ray:
  # https://docs.aws.amazon.com/service-authorization/latest/reference/list_awsx-ray.html); the OTLP traces endpoint
  # authorizes spans as this action.
  statement {
    sid       = "WriteSpans"
    actions   = ["xray:PutTraceSegments"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "prometheus_agent" {
  statement {
    sid       = "WriteMetrics"
    actions   = ["aps:RemoteWrite"]
    resources = [var.amp_workspace_arn]
  }
}

data "aws_iam_policy_document" "ack_prometheusservice" {
  statement {
    sid = "ManageRuleGroupsNamespaces"
    actions = [
      "aps:CreateRuleGroupsNamespace",
      "aps:PutRuleGroupsNamespace",
      "aps:DescribeRuleGroupsNamespace",
      "aps:DeleteRuleGroupsNamespace",
      "aps:TagResource",
      "aps:UntagResource",
      "aps:ListTagsForResource",
    ]
    resources = [local.rule_groups_namespaces_arn]
  }

  statement {
    sid = "ManageAlertManagerDefinition"
    actions = [
      "aps:CreateAlertManagerDefinition",
      "aps:PutAlertManagerDefinition",
      "aps:DescribeAlertManagerDefinition",
      "aps:DeleteAlertManagerDefinition",
      "aps:ListRuleGroupsNamespaces",
    ]
    resources = [var.amp_workspace_arn]
  }
}

# No KMS permission: ECR decrypts layers of a repository under a customer managed key through its own grant.
data "aws_iam_policy_document" "kyverno_admission" {
  # Resource * because the action has no resource type (Service Authorization Reference, Amazon ECR:
  # https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonelasticcontainerregistry.html).
  statement {
    sid       = "GetRegistryToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Manifests, referrers (signatures, attestations) and the layers of their bundles, in release repositories only.
  statement {
    sid       = "ReadReleaseImages"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = var.release_repository_arns
  }
}

# The canary analysis only runs instant queries, so QueryMetrics is all it needs.
data "aws_iam_policy_document" "argo_rollouts" {
  statement {
    sid       = "QueryMetrics"
    actions   = ["aps:QueryMetrics"]
    resources = [var.amp_workspace_arn]
  }
}

resource "aws_iam_role" "pod_identity" {
  for_each = local.pod_identity_roles

  name               = "${var.name}-${each.value.role}"
  description        = "${each.value.description} of EKS cluster ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust[each.key].json
}

resource "aws_iam_role_policy" "pod_identity" {
  for_each = local.pod_identity_roles

  name   = "${var.name}-${each.value.role}"
  role   = aws_iam_role.pod_identity[each.key].id
  policy = each.value.policy
}
