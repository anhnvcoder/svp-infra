# Remote state of every root of the repository: one key per root (aws/bootstrap/terraform.tfstate,
# aws/stg/terraform.tfstate, ...), locked with the S3 backend's native lock file, so no DynamoDB table.

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

# SSE-S3: encrypted at rest at no cost. A customer managed KMS key (what the finding below asks for) adds $1 a month and
# a key policy to keep, and draws no line that IAM and the bucket policy do not draw already in a one-person sandbox.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
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
