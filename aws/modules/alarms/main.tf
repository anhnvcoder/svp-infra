# The SNS topic every CloudWatch alarm of an env notifies, encrypted with a key of the module, and its email
# subscription. Design notes: aws/modules/alarms/README.md.

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  topic_name = "${var.name}-alarms"

  # Built from its parts rather than read from the topic, so both policies are known at plan time.
  topic_arn = "arn:${data.aws_partition.current.partition}:sns:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${local.topic_name}"

  # Confused deputy conditions of the CloudWatch and SNS guides: CloudWatch acts only for alarms of this account and region.
  source_account   = data.aws_caller_identity.current.account_id
  source_alarm_arn = "arn:${data.aws_partition.current.partition}:cloudwatch:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:alarm:*"
}

################################################################################
# Encryption key
################################################################################

# CloudWatch cannot publish to a topic under the AWS managed key of SNS: its key policy cannot be changed to let the
# CloudWatch service principal use it. The first statement is the default key policy, IAM of the account decides who
# else may use the key; the second gives CloudWatch only what publishing to an encrypted topic takes.
data "aws_iam_policy_document" "key" {
  statement {
    sid       = "EnableIamUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.source_account}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarmsUseKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.source_account]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.source_alarm_arn]
    }
  }
}

resource "aws_kms_key" "this" {
  description              = "SNS topic ${local.topic_name}: CloudWatch alarms of ${var.name}"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 7
  policy                   = data.aws_iam_policy_document.key.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-alarms"
  target_key_id = aws_kms_key.this.key_id
}

################################################################################
# Topic
################################################################################

# The topic names the key by its alias: SNS takes an alias, and the alias name is known at plan time where the key ARN
# is not. The alias belongs to this module and points at the key above only.
resource "aws_sns_topic" "this" {
  name              = local.topic_name
  kms_master_key_id = aws_kms_alias.this.name
}

# Replaces the default topic policy: only CloudWatch alarms of this account publish through the policy, over TLS only.
# Principals of the account still manage and publish through their IAM policies.
data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "CloudWatchAlarmsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [local.topic_arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.source_account]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.source_alarm_arn]
    }
  }

  statement {
    sid       = "DenyPublishWithoutTls"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [local.topic_arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "this" {
  arn    = aws_sns_topic.this.arn
  policy = data.aws_iam_policy_document.topic.json
}

# Stays "pending confirmation" until the link SNS emails is opened; Terraform cannot confirm an email subscription.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.this.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
