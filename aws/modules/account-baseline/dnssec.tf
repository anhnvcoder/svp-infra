# DNSSEC signing of the zone, its key and the alarms that page before a failing key stops the zone resolving.
# Design notes: aws/modules/account-baseline/README.md.

locals {
  # Route 53 takes the DNSSEC key, the query log group and the alarms on their metrics in us-east-1 only.
  global_region = "us-east-1"

  dnssec_count = var.dnssec_enabled ? 1 : 0

  runbook_base_url = "https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks"

  dnssec_alarms = {
    dnssec-internal-failure = {
      metric  = "DNSSECInternalFailure"
      summary = "DNSSEC of ${var.zone_name} has an object in INTERNAL_FAILURE: Route 53 cannot sign the zone."
    }
    dnssec-ksk-action-needed = {
      metric  = "DNSSECKeySigningKeysNeedingAction"
      summary = "A key signing key of ${var.zone_name} is in ACTION_NEEDED (its KMS key cannot be used): the zone stops resolving once its signatures expire."
    }
  }
}

# Key policy of the Route 53 DNSSEC guide: the account administers the key through IAM; the DNSSEC service signs with
# it for hosted zones of this account only, and creates grants for AWS resources only.
data "aws_iam_policy_document" "dnssec_key" {
  count = local.dnssec_count

  statement {
    sid       = "EnableIamUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid       = "Route53DnssecUseKey"
    effect    = "Allow"
    actions   = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["dnssec-route53.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:route53:::hostedzone/*"]
    }
  }

  statement {
    sid       = "Route53DnssecCreateGrant"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["dnssec-route53.amazonaws.com"]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

# An asymmetric key does not rotate; a new KSK replaces it instead.
resource "aws_kms_key" "dnssec" {
  count = local.dnssec_count

  region                   = local.global_region
  description              = "DNSSEC key signing key of ${var.zone_name}"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.dnssec_key[0].json

  # Deleting it while the parent zone holds a DS record for it makes the zone unresolvable. Signing stops through
  # dnssec_signing; the key leaves only by the removal steps of the README.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "dnssec" {
  count = local.dnssec_count

  region        = local.global_region
  name          = "alias/svp-dnssec"
  target_key_id = aws_kms_key.dnssec[0].key_id
}

# Always ACTIVE: Route 53 refuses to deactivate the only KSK of a zone that still signs, and Terraform would update this
# before the signing status below. Its delete deactivates it first. Route 53 takes only letters, digits and underscores
# in a KSK name, hence not the svp-<env>- form of other names.
resource "aws_route53_key_signing_key" "this" {
  count = local.dnssec_count

  hosted_zone_id             = aws_route53_zone.env.zone_id
  key_management_service_arn = aws_kms_key.dnssec[0].arn
  name                       = "svp_${var.env}_ksk"
  status                     = "ACTIVE"
}

resource "aws_route53_hosted_zone_dnssec" "this" {
  count = local.dnssec_count

  hosted_zone_id = aws_route53_key_signing_key.this[0].hosted_zone_id
  signing_status = var.dnssec_signing ? "SIGNING" : "NOT_SIGNING"
}

resource "aws_cloudwatch_metric_alarm" "dnssec" {
  for_each = var.dnssec_enabled ? local.dnssec_alarms : {}

  region              = local.global_region
  alarm_name          = "svp-${var.env}-${each.key}"
  alarm_description   = "${each.value.summary} Runbook: ${local.runbook_base_url}/${each.key}.md"
  namespace           = "AWS/Route53"
  metric_name         = each.value.metric
  dimensions          = { HostedZoneId = aws_route53_zone.env.zone_id }
  statistic           = "Sum"
  period              = 300
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  datapoints_to_alarm = 1
  evaluation_periods  = 1
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  tags = {
    Severity = "page"
  }
}
