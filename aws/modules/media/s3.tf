# Two private buckets. Keys keep their prefix: the uploads bucket holds uploads/<video_id>, the media bucket
# media/<video_id>/<version>/..., so the object keys, the IAM policies and the media URLs are the same on every
# object store of the platform.

# Bucket names are global. <name>-<account>-<region>, the convention of AWS's own buckets, is unique without a random
# part and tells the account and region at a glance. AWS does not treat an account id as a secret, and the uploads
# bucket name shows in every presigned upload form a browser gets; the account still comes in only at run time.
locals {
  bucket_suffix = "${var.account_id}-${var.region}"
  buckets = {
    uploads = "${var.name_prefix}-uploads-${local.bucket_suffix}"
    media   = "${var.name_prefix}-media-${local.bucket_suffix}"
  }

  # Built from the names rather than read from the buckets, so the policies that use them are known at plan time.
  bucket_arns = { for k, name in local.buckets : k => "arn:${data.aws_partition.current.partition}:s3:::${name}" }
}

data "aws_partition" "current" {}

# Backup = daily puts both buckets in the selection of the organization's backup policy. The keys are written out:
# trivy expands no for_each whose values it cannot read whole, and the names hold an account id it never knows, so it
# could not check the encryption of each bucket on its own.
resource "aws_s3_bucket" "this" {
  for_each = toset(["uploads", "media"])

  bucket        = local.buckets[each.key]
  force_destroy = var.force_destroy

  tags = {
    Backup = "daily"
  }
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

# Originals users send stay private for good, so they get a key of the env: reading one takes kms:Decrypt on that key
# besides s3:GetObject, and every use shows in CloudTrail. Default key policy: IAM of the account decides who uses it.
# The Bucket Key makes S3 ask KMS for a bucket-level key instead of once per object (up to 99 % fewer requests).
resource "aws_kms_key" "uploads" {
  description              = "S3 ${local.buckets["uploads"]}: default encryption of the uploads"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 7
}

resource "aws_kms_alias" "uploads" {
  name          = "alias/${var.name_prefix}-uploads"
  target_key_id = aws_kms_key.uploads.key_id
}

# uploads: the key above with the Bucket Key. media is public through CloudFront once transcoded, so it keeps SSE-S3: a
# customer managed key (what the finding below asks for) would add $1 a month and kms:Decrypt for CloudFront and both
# services, and protect nothing secret. Its key is "", not null: trivy reads null as unknown and checks nothing.
# Scope: every environment.
#trivy:ignore:AWS-0132[each.key=media]
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = each.key == "uploads" ? "aws:kms" : "AES256"
      kms_master_key_id = each.key == "uploads" ? aws_kms_key.uploads.arn : ""
    }
    bucket_key_enabled = each.key == "uploads" ? true : null
  }
}

# Versioning is off by default: media objects are written once under a new version path and never overwritten,
# uploads are deleted once they are no longer needed, and kept versions would only keep deleted bytes billed. On, a
# deleted or overwritten object stays restorable for noncurrent_days below (the lifecycle rules drop it then), which
# is what production wants against a mistaken delete.
locals {
  noncurrent_days = 30
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = var.versioning_enabled ? aws_s3_bucket.this : {}

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

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

  # Only with versioning on: older versions go noncurrent_days after they were replaced or deleted, and a delete
  # marker with no version left behind it goes too.
  dynamic "rule" {
    for_each = var.versioning_enabled ? [1] : []

    content {
      id     = "expire-noncurrent-versions"
      status = "Enabled"

      filter {}

      noncurrent_version_expiration {
        noncurrent_days = local.noncurrent_days
      }

      expiration {
        expired_object_delete_marker = true
      }
    }
  }

  # A lifecycle configuration written before versioning is on may be refused or applied to the wrong state.
  depends_on = [aws_s3_bucket_versioning.this]
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

  # The transcode job record of a version decides its result only while a job, an SQS message or a Kafka record of it
  # can still arrive; 30 days outlasts all three.
  rule {
    id     = "expire-transcode-jobs"
    status = "Enabled"

    filter {
      prefix = "transcode-jobs/"
    }

    expiration {
      days = 30
    }
  }

  # Only with versioning on: older versions go noncurrent_days after they were replaced or deleted, and a delete
  # marker with no version left behind it goes too.
  dynamic "rule" {
    for_each = var.versioning_enabled ? [1] : []

    content {
      id     = "expire-noncurrent-versions"
      status = "Enabled"

      filter {}

      noncurrent_version_expiration {
        noncurrent_days = local.noncurrent_days
      }

      expiration {
        expired_object_delete_marker = true
      }
    }
  }

  # A lifecycle configuration written before versioning is on may be refused or applied to the wrong state.
  depends_on = [aws_s3_bucket_versioning.this]
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
    resources = ["${local.bucket_arns["media"]}/media/*"]

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
