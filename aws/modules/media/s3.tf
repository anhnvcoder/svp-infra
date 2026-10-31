# Two private buckets. Keys keep their prefix: the uploads bucket holds uploads/<video_id>, the media bucket
# media/<video_id>/<version>/..., so the object keys, the IAM policies and the media URLs are the same on every
# object store of the platform.

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  buckets = {
    uploads = "${var.name_prefix}-uploads-${random_id.suffix.hex}"
    media   = "${var.name_prefix}-media-${random_id.suffix.hex}"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = each.value
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs off: access is decided by IAM and the bucket policy alone.
resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# SSE-S3: encrypted at rest at no cost. A customer managed KMS key (what the finding below asks for) adds $1 a month,
# a key policy, and kms:Decrypt for CloudFront and both services, and draws no line the bucket policy and IAM do not
# draw already.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning stays off: media objects are written once under a new version path and never overwritten, uploads are
# deleted once they are no longer needed, and kept versions would only keep deleted bytes billed.

# The browser posts the presigned upload form straight to the uploads bucket with XHR, and reads the Retry-After of a
# refusal, which a cross-origin answer only shows when exposed. POST only: nothing else may come from a page.
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.this["uploads"].id

  cors_rule {
    allowed_methods = ["POST"]
    allowed_origins = var.cors_allowed_origins
    allowed_headers = ["*"]
    expose_headers  = ["Retry-After"]
    max_age_seconds = 600
  }
}

# Same rule as the local object store. Viewers reach media through CloudFront, which sends no Origin to the bucket
# and adds the CORS headers itself (cloudfront.tf), so this rule only answers a request made to the bucket directly.
resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.this["media"].id

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = var.cors_allowed_origins
    allowed_headers = ["*"]
    max_age_seconds = 600
  }
}

# Original uploads stay 30 days in the standard class, where a video can still be transcoded again, then go to Glacier
# Deep Archive (reading them back takes a restore of up to 48 hours) and are deleted after a year.
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.this["uploads"].id

  rule {
    id     = "archive-originals"
    status = "Enabled"

    filter {
      prefix = "uploads/"
    }

    transition {
      days          = 30
      storage_class = "DEEP_ARCHIVE"
    }

    expiration {
      days = 365
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# No service writes with multipart uploads today (one PutObject per file; the browser form is a single POST), but
# s3:PutObject lets either service start one and neither may abort it (no s3:AbortMultipartUpload). Parts left by an
# unfinished upload, from a later client or a misused credential, would stay billed and show in no listing; this rule
# drops them, as on the uploads bucket.
resource "aws_s3_bucket_lifecycle_configuration" "media" {
  bucket = aws_s3_bucket.this["media"].id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Requests over plain HTTP are refused on both buckets: the services, the upload forms and CloudFront all use HTTPS.
# The statement denies s3:*, as AWS's own TLS-only bucket policy does, so that an action S3 adds later is refused over
# HTTP too. A Deny grants nothing: the wildcard widens what is refused, never what is allowed.
data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.this

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]

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

# The media bucket stays private: only this distribution may read, through its origin access control, and only single
# objects under media/, never a listing (a missing key then answers 403, not 404).
data "aws_iam_policy_document" "media" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["media"].json]

  statement {
    sid       = "CloudFrontReadMedia"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["media"].arn}/media/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.media.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "uploads" {
  bucket = aws_s3_bucket.this["uploads"].id
  policy = data.aws_iam_policy_document.tls_only["uploads"].json

  # S3 rejects a policy write while the public access block of the same bucket is being changed.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.this["media"].id
  policy = data.aws_iam_policy_document.media.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
