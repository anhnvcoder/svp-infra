locals {
  # <name>-<account>-<region>, as the bucket of aws/bootstrap: unique without a random part.
  state_bucket = "svp-tfstate-${var.account_id}-${var.region}"
}

# Remote state of every root that changes this account: one key per root, locked with the S3 backend's native lock
# file, so no DynamoDB table.
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  # Losing this bucket loses the state of every root of the account. Removing it on purpose: aws/accounts/README.md.
  lifecycle {
    prevent_destroy = true
  }
}

# Every write keeps the previous version, so a state broken by a bad apply or a manual edit can be restored.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Every object is encrypted with the state key, whatever the client asks for. The S3 Bucket Key cuts the KMS requests
# to one per bucket key instead of one per object.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs off: access is decided by IAM, the bucket policy and the key policy alone.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  # S3 rejects a policy write while the public access block is being changed on the same bucket.
  depends_on = [aws_s3_bucket_public_access_block.state]
}
