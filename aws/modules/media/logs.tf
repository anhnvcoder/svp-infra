# S3 server access logs of the uploads and media buckets (access_logging_enabled): one line per request, with the
# caller, the key and the result, into a bucket of their own. Off by default: the logs cost requests and storage, and
# a lab session has CloudTrail and the services' own logs.
#
# The log bucket logs nothing itself: logging its own writes would add a line for every line it receives
# (https://docs.aws.amazon.com/AmazonS3/latest/userguide/enable-server-access-logging.html).

locals {
  log_bucket = "${var.name_prefix}-logs-${local.bucket_suffix}"
  # Days a log object is kept before the lifecycle rule deletes it.
  log_expiration_days = 90
}

resource "aws_s3_bucket" "logs" {
  count = var.access_logging_enabled ? 1 : 0

  bucket        = local.log_bucket
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count = var.access_logging_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs off: S3 delivers the logs under the bucket policy below, not through the log-delivery group's ACL.
resource "aws_s3_bucket_ownership_controls" "logs" {
  count = var.access_logging_enabled ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# SSE-S3, the only default encryption a server access log destination may use: with SSE-KMS, S3 may deliver log
# objects encrypted with a key the owner cannot use (same page as above).
# Scope: every environment.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  count = var.access_logging_enabled ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  count = var.access_logging_enabled ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = local.log_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# TLS only, as on the other two buckets, and the policy of the S3 guide for log delivery: the logging service may
# write objects, only for the two buckets of this module and only in this account.
data "aws_iam_policy_document" "logs" {
  count = var.access_logging_enabled ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs[0].arn, "${aws_s3_bucket.logs[0].arn}/*"]

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

  statement {
    sid       = "S3ServerAccessLogsPolicy"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs[0].arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [for b in aws_s3_bucket.this : b.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  count = var.access_logging_enabled ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id
  policy = data.aws_iam_policy_document.logs[0].json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# Each bucket logs under a prefix of its own key in the map (uploads/, media/).
resource "aws_s3_bucket_logging" "this" {
  for_each = var.access_logging_enabled ? aws_s3_bucket.this : {}

  bucket        = each.value.id
  target_bucket = aws_s3_bucket.logs[0].id
  target_prefix = "${each.key}/"

  # Delivery checks the destination's policy when logging is turned on.
  depends_on = [aws_s3_bucket_policy.logs]
}
