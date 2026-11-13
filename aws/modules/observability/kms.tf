locals {
  # The "key administrators" actions of the AWS KMS default key policy
  # (https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html): manage the key, never use it.
  key_admin_actions = [
    "kms:Create*",
    "kms:Describe*",
    "kms:Enable*",
    "kms:List*",
    "kms:Put*",
    "kms:Update*",
    "kms:Revoke*",
    "kms:Disable*",
    "kms:Get*",
    "kms:Delete*",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:ScheduleKeyDeletion",
    "kms:CancelKeyDeletion",
    "kms:RotateKeyOnDemand",
  ]

  key_use_actions = [
    "kms:Encrypt",
    "kms:Decrypt",
    "kms:ReEncrypt*",
    "kms:GenerateDataKey*",
    "kms:DescribeKey",
  ]
}

# The account administers the key through IAM but uses it only through AMP and CloudWatch Logs (kms:ViaService), so
# no principal of the account can decrypt telemetry outside those services. No statement names another account or "*".
data "aws_iam_policy_document" "observability_key" {
  statement {
    sid       = "AccountAdministersKey"
    effect    = "Allow"
    actions   = local.key_admin_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # Who creates the workspace grants AMP the key; AMP then works through its own grants
  # (https://docs.aws.amazon.com/prometheus/latest/userguide/encryption-at-rest-Amazon-Service-Prometheus.html).
  statement {
    sid       = "AccountUsesKeyThroughPrometheus"
    effect    = "Allow"
    actions   = ["kms:DescribeKey", "kms:CreateGrant", "kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["aps.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }
  }

  # Writers and readers of the encrypted log group (the Collector, the Grafana workspace) through their IAM policies.
  statement {
    sid       = "AccountUsesKeyThroughLogs"
    effect    = "Allow"
    actions   = local.key_use_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }
  }

  # CloudWatch Logs itself, for this log group only
  # (https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html).
  statement {
    sid       = "LogsEncryptsApplicationLogGroup"
    effect    = "Allow"
    actions   = local.key_use_actions
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [local.log_group_arn]
    }
  }
}

resource "aws_kms_key" "observability" {
  description             = "Metrics and application logs of ${local.name}: Prometheus workspace and log group ${local.log_group_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.observability_key.json

  # AMP binds a workspace to its key for good: without the key every metric of the workspace is lost.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "observability" {
  name          = "alias/${local.name}-observability"
  target_key_id = aws_kms_key.observability.key_id
}
