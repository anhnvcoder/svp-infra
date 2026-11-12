resource "aws_s3_bucket" "log" {
  for_each = local.buckets

  region = each.value.region
  bucket = each.value.name
  # Object Lock can only be turned on, never off, and implies versioning.
  object_lock_enabled = each.value.object_lock

  # Losing a bucket loses the history of the organization. Removing one on purpose: see README.md.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "log" {
  for_each = local.buckets

  region = each.value.region
  bucket = aws_s3_bucket.log[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Governance mode: no one deletes or overwrites a trail log version before its year is up unless they hold
# s3:BypassGovernanceRetention and send the bypass header on purpose. Only the trail bucket: AWS Config refuses a
# bucket with a default retention, and S3 server access logs refuse Object Lock.
resource "aws_s3_bucket_object_lock_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.log["cloudtrail"].id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = local.audit_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.log]
}

# SSE-S3 for the access log bucket only: S3 server access logging delivers to no other encryption. The S3 Bucket Key
# cuts the KMS requests of the others.
resource "aws_s3_bucket_server_side_encryption_configuration" "log" {
  for_each = local.buckets

  region = each.value.region
  bucket = aws_s3_bucket.log[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = each.value.key == null ? "AES256" : "aws:kms"
      kms_master_key_id = each.value.key == null ? null : aws_kms_key.log[each.value.key].arn
    }
    bucket_key_enabled = each.value.key != null
  }
}

resource "aws_s3_bucket_public_access_block" "log" {
  for_each = local.buckets

  region = each.value.region
  bucket = aws_s3_bucket.log[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs off: access is decided by IAM and the bucket policy alone. The delivering services still send
# bucket-owner-full-control, which BucketOwnerEnforced accepts.
resource "aws_s3_bucket_ownership_controls" "log" {
  for_each = local.buckets

  region = each.value.region
  bucket = aws_s3_bucket.log[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Where two expirations overlap, S3 applies the shorter one: the stg rule cuts the stg account's logs to a week. S3
# does not move objects under 128 KB to another class, so most log files stay in S3 Standard until they expire.
resource "aws_s3_bucket_lifecycle_configuration" "log" {
  for_each = local.buckets

  region = each.value.region
  bucket = aws_s3_bucket.log[each.key].id

  rule {
    id     = "retention"
    status = "Enabled"

    filter {}

    dynamic "transition" {
      for_each = each.value.cold_after_days == null ? [] : [each.value.cold_after_days]

      content {
        days          = transition.value
        storage_class = "GLACIER_IR"
      }
    }

    expiration {
      days = each.value.retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  dynamic "rule" {
    for_each = each.value.stg_prefix == null ? [] : [each.value.stg_prefix]

    content {
      id     = "stg-retention"
      status = "Enabled"

      filter {
        prefix = rule.value
      }

      expiration {
        days = local.stg_network_retention_days
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.log]
}

# Server access logging of the trail bucket (CIS AWS Foundations Benchmark v5.0.0, 3.4): who read or deleted log files.
# The access log bucket is not logged itself: it would log its own writes without end.
resource "aws_s3_bucket_logging" "cloudtrail" {
  bucket        = aws_s3_bucket.log["cloudtrail"].id
  target_bucket = aws_s3_bucket.log["cloudtrail_access"].id
  target_prefix = "${local.buckets.cloudtrail.name}/"
}

resource "aws_s3_bucket_policy" "log" {
  for_each = local.buckets

  region = each.value.region
  bucket = aws_s3_bucket.log[each.key].id
  policy = data.aws_iam_policy_document.bucket[each.key].json

  lifecycle {
    # A wrong TF_VAR_account_id would let no trail write here; stop before the policies name it.
    precondition {
      condition     = data.aws_organizations_organization.this.master_account_id == var.account_id
      error_message = "account_id is not the management account of the organization (TF_VAR_account_id from SVP_AWS_MGMT_ACCOUNT_ID)."
    }
  }

  # S3 rejects a policy write while the public access block is being changed on the same bucket.
  depends_on = [aws_s3_bucket_public_access_block.log]
}
