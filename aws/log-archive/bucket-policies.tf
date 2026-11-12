# Each bucket admits only the service that delivers into it, from this organization, as its service's documentation
# shows; aws:SourceOrgID instead of a list of accounts lets a new account deliver without a policy change. Every
# request without TLS is refused.

locals {
  service_bucket_policies = {
    cloudtrail        = data.aws_iam_policy_document.cloudtrail_bucket.json
    cloudtrail_access = data.aws_iam_policy_document.cloudtrail_access_bucket.json
    config            = data.aws_iam_policy_document.config_bucket.json
    flowlogs          = data.aws_iam_policy_document.log_delivery_bucket["flowlogs"].json
    guardduty         = data.aws_iam_policy_document.guardduty_bucket.json
    waf               = data.aws_iam_policy_document.log_delivery_bucket["waf"].json
    cloudfront        = data.aws_iam_policy_document.cloudfront_bucket.json
  }
}

data "aws_iam_policy_document" "bucket" {
  for_each = local.buckets

  source_policy_documents = [local.service_bucket_policies[each.key]]

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      local.bucket_arns[each.key],
      "${local.bucket_arns[each.key]}/*",
    ]

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

# The organization trail of the management account writes under AWSLogs/<management account>/ and
# AWSLogs/<organization id>/, only for the trail svp-audit.
data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [local.bucket_arns.cloudtrail]

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
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${local.bucket_arns.cloudtrail}/AWSLogs/${var.account_id}/*",
      "${local.bucket_arns.cloudtrail}/AWSLogs/${local.org_id}/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

# The S3 logging service writes only the access logs of the trail bucket of this account.
data "aws_iam_policy_document" "cloudtrail_access_bucket" {
  statement {
    sid       = "S3ServerAccessLogsPolicy"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arns.cloudtrail_access}/${local.buckets.cloudtrail.name}/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.bucket_arns.cloudtrail]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.log_archive_account_id]
    }
  }
}

# AWS Config of every account and region of the organization: history and snapshots under AWSLogs/<account>/Config/.
data "aws_iam_policy_document" "config_bucket" {
  statement {
    sid       = "AWSConfigBucketPermissionsCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [local.bucket_arns.config]

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
    sid       = "AWSConfigBucketDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arns.config}/AWSLogs/*"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [local.org_id]
    }
  }
}

# The log delivery service of CloudWatch: VPC flow logs of the env accounts, and WAF logs, whose bucket name must start
# with aws-waf-logs-.
data "aws_iam_policy_document" "log_delivery_bucket" {
  for_each = toset(["flowlogs", "waf"])

  statement {
    sid       = "AWSLogDeliveryAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [local.bucket_arns[each.key]]

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

  statement {
    sid       = "AWSLogDeliveryWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arns[each.key]}/AWSLogs/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [local.org_id]
    }
  }
}

# GuardDuty exports the findings of the detectors of svp-security, both regions, into this bucket.
data "aws_iam_policy_document" "guardduty_bucket" {
  statement {
    sid       = "AllowGuardDutyGetBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [local.bucket_arns.guardduty]

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

  statement {
    sid       = "AllowGuardDutyPutObject"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arns.guardduty}/*"]

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

# Standard logs (v2) of CloudFront: the log delivery service writes for a delivery source of us-east-1 in an account
# of the organization; each env's destination fixes its own AWSLogs/<account>/CloudFront prefix.
data "aws_iam_policy_document" "cloudfront_bucket" {
  statement {
    sid       = "AWSLogDeliveryWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arns.cloudfront}/AWSLogs/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [local.org_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:logs:${local.key_regions.waf}:*:delivery-source:*"]
    }
  }
}
