# Remote state of the roots run with the management account's profile (the list is in aws/bootstrap/README.md), one key
# per root, locked with the S3 backend's native lock file, so no DynamoDB table. The roots of each environment keep
# their state in the bucket of their own account (aws/accounts/<env>).

# Bucket names are global. <name>-<account>-<region>, the convention of AWS's own buckets (the CDK bootstrap bucket,
# the Control Tower log bucket), is unique without a random part and tells the account and region at a glance. AWS
# does not treat an account id as a secret; it still enters the name only at run time, from var.account_id, so no
# committed file holds the real account.
resource "aws_s3_bucket" "state" {
  bucket = "svp-tfstate-${var.account_id}-${var.region}"

  # Losing this bucket loses the state of every root. Removing it on purpose: see aws/bootstrap/README.md.
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

# The key policy is the AWS default one: the account's IAM policies decide who uses the key, as they decide who reads
# the bucket. The permission sets of the management account are not managed in this repository, so no statement can
# name the roles that should read state, as the key of each environment's state does (aws/modules/account-baseline).
resource "aws_kms_key" "state" {
  description             = "Terraform state of the management account (bucket ${aws_s3_bucket.state.bucket})"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # Without this key the state in the bucket cannot be read. Removing both on purpose: aws/bootstrap/README.md.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/svp-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# Every object is encrypted with the state key unless the client asks for another encryption. The S3 Bucket Key cuts
# the KMS requests to one per bucket key instead of one per object.
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

# ACLs off: access is decided by IAM and the bucket policy alone.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "state" {
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
  policy = data.aws_iam_policy_document.state.json

  # S3 rejects a policy write while the public access block is being changed on the same bucket.
  depends_on = [aws_s3_bucket_public_access_block.state]
}
