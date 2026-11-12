# The SNS topic the alarms of an env (or the security events of the organization) notify, encrypted with a key of the
# module, and its email subscription. Design notes: aws/modules/alarms/README.md.

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  topic_name = "${var.name}-alarms"
  region     = coalesce(var.region, data.aws_region.current.region)

  # Built from its parts rather than read from the topic, so both policies are known at plan time.
  topic_arn = "arn:${data.aws_partition.current.partition}:sns:${local.region}:${data.aws_caller_identity.current.account_id}:${local.topic_name}"

  # Confused deputy conditions of the service guides: each publisher acts only for its own resources (CloudWatch alarms,
  # EventBridge rules) of this account and region. SNS does not support them in the key policy for EventBridge to an
  # encrypted topic, so for EventBridge only the topic policy carries them.
  source_account = data.aws_caller_identity.current.account_id
  arn_prefix     = "arn:${data.aws_partition.current.partition}"
  account_region = "${local.region}:${data.aws_caller_identity.current.account_id}"
  publishers = {
    "cloudwatch.amazonaws.com" = { sid = "CloudWatchAlarms", label = "CloudWatch alarms", source_arn = "${local.arn_prefix}:cloudwatch:${local.account_region}:alarm:*", key_source_conditions = true }
    "events.amazonaws.com"     = { sid = "EventBridgeRules", label = "EventBridge rules", source_arn = "${local.arn_prefix}:events:${local.account_region}:rule/*", key_source_conditions = false }
  }
  source_conditions = { for service, p in local.publishers : service => [
    { test = "StringEquals", variable = "aws:SourceAccount", values = [local.source_account] },
    { test = "ArnLike", variable = "aws:SourceArn", values = [p.source_arn] },
  ] }
}

################################################################################
# Encryption key
################################################################################

# CloudWatch and EventBridge cannot publish to a topic under the AWS managed key of SNS: its key policy cannot be
# changed to let a service principal use it. The first statement is the default key policy, IAM of the account decides
# who else may use the key; the others give each publisher only what publishing to an encrypted topic takes.
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

  dynamic "statement" {
    for_each = var.publisher_services

    content {
      sid       = "${local.publishers[statement.value].sid}UseKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = [statement.value]
      }

      dynamic "condition" {
        for_each = local.publishers[statement.value].key_source_conditions ? local.source_conditions[statement.value] : []

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_kms_key" "this" {
  region                   = var.region
  description              = "SNS topic ${local.topic_name}: ${join(" and ", [for p in var.publisher_services : local.publishers[p].label])} of ${var.name}"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 7
  policy                   = data.aws_iam_policy_document.key.json
}

resource "aws_kms_alias" "this" {
  region        = var.region
  name          = "alias/${var.name}-alarms"
  target_key_id = aws_kms_key.this.key_id
}

################################################################################
# Topic
################################################################################

# The topic names the key by its alias: SNS takes an alias, and the alias name is known at plan time where the key ARN
# is not. The alias belongs to this module and points at the key above only.
resource "aws_sns_topic" "this" {
  region            = var.region
  name              = local.topic_name
  kms_master_key_id = aws_kms_alias.this.name
}

# Replaces the default topic policy: only the publishers' resources of this account publish through the policy, over TLS
# only.
# Principals of the account still manage and publish through their IAM policies.
data "aws_iam_policy_document" "topic" {
  dynamic "statement" {
    for_each = var.publisher_services

    content {
      sid       = "${local.publishers[statement.value].sid}Publish"
      effect    = "Allow"
      actions   = ["sns:Publish"]
      resources = [local.topic_arn]

      principals {
        type        = "Service"
        identifiers = [statement.value]
      }

      dynamic "condition" {
        for_each = local.source_conditions[statement.value]

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
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
  region = var.region
  arn    = aws_sns_topic.this.arn
  policy = data.aws_iam_policy_document.topic.json
}

# Stays "pending confirmation" until the link SNS emails is opened; Terraform cannot confirm an email subscription.
resource "aws_sns_topic_subscription" "email" {
  region    = var.region
  topic_arn = aws_sns_topic.this.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
