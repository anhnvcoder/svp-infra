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

# Neither the workspace nor the log group is encrypted with this key any more; log events written before stay encrypted
# with it until log_retention_days pass, so CloudWatch Logs and the account's readers still use it, and only through
# CloudWatch Logs (kms:ViaService). The account administers it through IAM. No statement names another account or "*".
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

  # Readers of the log events encrypted before the switch (Grafana workspace, console) through their IAM policies.
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

  # Removing the block would schedule the deletion of the key and leave the older log events unreadable.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "observability" {
  name          = "alias/${local.name}-observability"
  target_key_id = aws_kms_key.observability.key_id
}
