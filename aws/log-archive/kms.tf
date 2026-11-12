resource "aws_kms_key" "log" {
  for_each = local.key_regions

  region      = each.value
  description = "Encrypts the logs of the organization in the log archive buckets of ${each.value}"
  # The longest waiting period: a key scheduled for deletion by mistake can be cancelled for 30 days, after which
  # every log it encrypted is unreadable.
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = local.key_policies[each.key]

  lifecycle {
    prevent_destroy = true
  }
}

# Same alias in both regions, so a reader's IAM policy names one alias for both keys.
resource "aws_kms_alias" "log" {
  for_each = local.key_regions

  region        = each.value
  name          = "alias/svp-log-archive"
  target_key_id = aws_kms_key.log[each.key].key_id
}

locals {
  key_policies = {
    home = data.aws_iam_policy_document.key_home.json
    waf  = data.aws_iam_policy_document.key_common.json
  }
}

# Both keys: the account manages and reads through IAM (readers get kms:Decrypt by their own policy); the log delivery
# service of CloudWatch (flow logs, WAF logs) encrypts for any account of the organization.
data "aws_iam_policy_document" "key_common" {
  statement {
    sid       = "EnableIamPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${var.log_archive_account_id}:root"]
    }
  }

  statement {
    sid    = "AllowLogDeliveryUseOfTheKey"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [local.org_id]
    }
  }
}

# The home key also serves the organization trail, AWS Config and the GuardDuty finding export, each with the
# conditions of its service's documentation.
data "aws_iam_policy_document" "key_home" {
  source_policy_documents = [data.aws_iam_policy_document.key_common.json]

  statement {
    sid       = "AllowCloudTrailEncryptLogs"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${var.account_id}:trail/*"]
    }
  }

  # DescribeKey carries no encryption context, so it gets its own statement.
  statement {
    sid       = "AllowCloudTrailDescribeKey"
    effect    = "Allow"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "AllowConfigUseOfTheKey"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [local.org_id]
    }
  }

  statement {
    sid       = "AllowGuardDutyEncryptFindings"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["guardduty.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.security_account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = local.guardduty_detector_arns
    }
  }
}
