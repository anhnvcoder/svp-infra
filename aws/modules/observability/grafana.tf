locals {
  # Log groups the workspace may query with Logs Insights: the application logs, the spans of Transaction Search and
  # the logs of the env's managed data services (names from the rds, msk and elasticache modules).
  grafana_log_groups = [
    local.log_group_name,
    "aws/spans",
    "/aws/rds/instance/${local.name}/*",
    "RDSOSMetrics",
    "/aws/msk/${local.name}",
    "/aws/elasticache/${local.name}/*",
  ]
  grafana_log_group_arns = flatten([for g in local.grafana_log_groups : [
    "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${g}",
    "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${g}:*",
  ]])
}

data "aws_iam_policy_document" "grafana_trust" {
  statement {
    sid     = "GrafanaAssumesRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["grafana.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# Read only, and only the env's telemetry: what AmazonGrafanaCloudWatchAccess and the Prometheus policy of a
# SERVICE_MANAGED workspace grant, narrowed to this account's workspace and log groups.
data "aws_iam_policy_document" "grafana" {
  statement {
    sid = "QueryPrometheus"
    actions = [
      "aps:QueryMetrics",
      "aps:GetSeries",
      "aps:GetLabels",
      "aps:GetMetricMetadata",
      "aps:ListRules",
      "aps:ListAlerts",
    ]
    resources = [local.amp_workspace_arn]
  }

  statement {
    sid       = "QueryLogGroups"
    actions   = ["logs:StartQuery", "logs:GetQueryResults", "logs:GetLogGroupFields"]
    resources = local.grafana_log_group_arns
  }

  # The Service Authorization Reference lists no resource type for these actions: they take only "*".
  statement {
    sid = "ActionsWithoutResourceType"
    actions = [
      "logs:StopQuery",
      "logs:DescribeLogGroups",
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DecryptLogsThroughCloudWatchLogs"
    actions   = ["kms:Decrypt"]
    resources = [local.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["logs.${local.region}.amazonaws.com"]
    }
  }

  # AMG reads an encrypted workspace only when its role may use the key
  # (https://docs.aws.amazon.com/prometheus/latest/userguide/encryption-at-rest-Amazon-Service-Prometheus.html).
  statement {
    sid       = "DecryptMetricsThroughPrometheus"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [local.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["aps.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "grafana" {
  name               = "${local.name}-grafana"
  description        = "Assumed by the Amazon Managed Grafana workspace ${local.name} to read its data sources"
  assume_role_policy = data.aws_iam_policy_document.grafana_trust.json
}

resource "aws_iam_role_policy" "grafana" {
  name   = "read-telemetry"
  role   = aws_iam_role.grafana.id
  policy = data.aws_iam_policy_document.grafana.json
}

# CUSTOMER_MANAGED is the only permission type the API can create. No VPC configuration: the workspace reaches AMP and
# CloudWatch at their public endpoints. grafana_version is left to the newest version AMG offers at creation.
resource "aws_grafana_workspace" "this" {
  name                     = local.name
  description              = "Dashboards of ${local.name}"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "CUSTOMER_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn
  data_sources             = ["PROMETHEUS", "CLOUDWATCH"]
}

resource "aws_grafana_role_association" "admin" {
  workspace_id = aws_grafana_workspace.this.id
  role         = "ADMIN"
  group_ids    = [var.platform_admin_group_id]
}

resource "aws_grafana_role_association" "viewer" {
  workspace_id = aws_grafana_workspace.this.id
  role         = "VIEWER"
  group_ids    = [var.platform_viewer_group_id]
}

# Grafana Operator signs in as this account; the session script makes its short-lived token, never Terraform, so no
# token sits in the state. ADMIN because the Operator creates the data sources, which an Editor may not add or edit
# (https://docs.aws.amazon.com/grafana/latest/userguide/Grafana-user-roles.html).
resource "aws_grafana_workspace_service_account" "operator" {
  workspace_id = aws_grafana_workspace.this.id
  name         = "svp-grafana-operator"
  grafana_role = "ADMIN"
}
