# Organization trail: the management events (read and write) of every account of the organization, in every region,
# and the S3 data events of the production user buckets, delivered to the log archive account (aws/log-archive), with
# log file integrity validation. Member accounts see the trail but cannot change it, and protect-cloudtrail of
# org-policies keeps them from changing any trail of their own. Lives between sessions. Design notes: README.md.

locals {
  trail_name = "svp-audit"
  # Known before the trail exists, so the key and bucket policies can name it without a cycle.
  trail_arn = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.region}:${var.account_id}:trail/${local.trail_name}"

  # One year of audit history, the common baseline (PCI DSS v4 requirement 10.5.1: at least 12 months, the last three
  # immediately available). Log files are locked for the same year, then expire.
  log_retention_days = 365
  # After three months nobody reads a log file but an investigation; Glacier Instant Retrieval still reads it in
  # milliseconds and its 90-day minimum storage is met.
  log_cold_after_days = 90
}

# The key and the two buckets below are where the trail wrote before the log archive account. They stay, read only,
# until Object Lock releases the last log file version they hold: deleting them earlier would lose audit history still
# under retention. README.md says how to remove them afterwards.
resource "aws_kms_key" "cloudtrail" {
  description         = "Encrypts the log files of the organization trail ${local.trail_name}"
  enable_key_rotation = true
  # The longest waiting period: a key scheduled for deletion by mistake can be cancelled for 30 days, after which
  # every log file it encrypted is unreadable.
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.cloudtrail_key.json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/svp-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail.key_id
}

# The key policy of the CloudTrail documentation ("Configure AWS KMS key policies for CloudTrail"): the account manages
# the key through IAM; CloudTrail may generate data keys and describe the key only for this trail (aws:SourceArn), and
# only with the encryption context of a trail of the management account, the owner of the organization trail whose
# ARN every member account's log files carry. Reading the logs (kms:Decrypt) goes through IAM of the management account.
data "aws_iam_policy_document" "cloudtrail_key" {
  statement {
    sid       = "EnableIamPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCloudTrailEncryptLogs"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${data.aws_partition.current.partition}:cloudtrail:*:${var.account_id}:trail/*"]
    }
  }

  statement {
    sid       = "AllowCloudTrailDescribeKey"
    effect    = "Allow"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]

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
}

# Log bucket. <name>-<account>-<region> like the state bucket. Object Lock in governance mode: no one deletes or
# overwrites a log file version before its year is up unless they hold s3:BypassGovernanceRetention and send the
# bypass header on purpose; compliance mode is not used, as not even the root user could remove it. Object Lock can
# only be turned on, never off, and implies versioning.
resource "aws_s3_bucket" "trail" {
  bucket              = "svp-cloudtrail-${var.account_id}-${var.region}"
  object_lock_enabled = true

  # Losing this bucket loses the audit history. Removing it on purpose: see README.md.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = local.log_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

# CloudTrail encrypts each log file with the trail key itself; the bucket default covers anything else written here.
# The S3 Bucket Key cuts the KMS requests of that default.
resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudtrail.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket = aws_s3_bucket.trail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs off: access is decided by IAM and the bucket policy alone. CloudTrail still sends bucket-owner-full-control,
# which BucketOwnerEnforced accepts.
resource "aws_s3_bucket_ownership_controls" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Lifecycle and Object Lock work together: expiring the current version adds a delete marker, and a locked version is
# removed only once its retention is over. S3 does not move objects under 128 KB to another class by default (a
# transition request and the 128 KB minimum billable size of Glacier Instant Retrieval cost more than the storage it
# saves), so most log files, a few KB each, stay in S3 Standard until they expire; the large ones move.
resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "audit-retention"
    status = "Enabled"

    filter {}

    transition {
      days          = local.log_cold_after_days
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = local.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

# The bucket policy of the CloudTrail documentation for an organization trail ("Amazon S3 bucket policy for
# CloudTrail"): CloudTrail checks the ACL and writes under AWSLogs/<management account>/ and AWSLogs/<organization id>/,
# only for this trail; every request without TLS is refused.
data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]

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
      "${aws_s3_bucket.trail.arn}/AWSLogs/${var.account_id}/*",
      "${aws_s3_bucket.trail.arn}/AWSLogs/${aws_organizations_organization.this.id}/*",
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

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.trail.arn,
      "${aws_s3_bucket.trail.arn}/*",
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

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json

  # S3 rejects a policy write while the public access block is being changed on the same bucket.
  depends_on = [aws_s3_bucket_public_access_block.trail]
}

# Server access logging of the log bucket (CIS AWS Foundations Benchmark v5.0.0, 3.4): who read or deleted log files.
resource "aws_s3_bucket_logging" "trail" {
  bucket        = aws_s3_bucket.trail.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "${aws_s3_bucket.trail.bucket}/"
}

# Bucket of the server access logs. S3 refuses a destination with Object Lock or with SSE-KMS default encryption, so
# this one has neither, and it is not logged itself (logging it into itself would log its own writes without end).
resource "aws_s3_bucket" "access_logs" {
  bucket = "svp-cloudtrail-access-${var.account_id}-${var.region}"

  lifecycle {
    prevent_destroy = true
  }
}

# S3 server access logging delivers only to a bucket encrypted with SSE-S3 (S3 user guide, "Enabling Amazon S3 server
# access logging"), so a customer managed key cannot be used here.
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "access-log-retention"
    status = "Enabled"

    filter {}

    expiration {
      days = local.log_retention_days
    }
  }
}

# The S3 logging service writes only access logs of the log bucket of this account (S3 user guide, "Enabling Amazon S3
# server access logging", bucket policy); every request without TLS is refused.
data "aws_iam_policy_document" "access_logs" {
  statement {
    sid       = "S3ServerAccessLogsPolicy"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs.arn}/${aws_s3_bucket.trail.bucket}/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.trail.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.access_logs.arn,
      "${aws_s3_bucket.access_logs.arn}/*",
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

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs.json

  depends_on = [aws_s3_bucket_public_access_block.access_logs]
}

locals {
  prd_id    = aws_organizations_account.member["prd"].id
  partition = data.aws_partition.current.partition
}

# Bucket and key policies of aws/log-archive allow only this trail (aws:SourceArn), which is why its name never changes.
data "aws_kms_alias" "log_archive" {
  provider = aws.log_archive

  name = "alias/svp-log-archive"
}

resource "aws_cloudtrail" "audit" {
  name           = local.trail_name
  s3_bucket_name = "svp-cloudtrail-${local.log_archive_id}-${var.region}"
  # The key/<id> form CloudTrail returns: an alias ARN here would show a difference on every plan.
  kms_key_id                    = data.aws_kms_alias.log_archive.target_key_arn
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  advanced_event_selector {
    name = "management"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  # Data events are billed per event, so only where real user data lives: the production uploads (read and write) and
  # the production media writes. Reads of media are viewer traffic through CloudFront.
  advanced_event_selector {
    name = "prd-uploads"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field       = "resources.ARN"
      starts_with = ["arn:${local.partition}:s3:::svp-prd-uploads-${local.prd_id}-${var.region}/"]
    }
  }

  advanced_event_selector {
    name = "prd-media-writes"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field  = "readOnly"
      equals = ["false"]
    }

    field_selector {
      field       = "resources.ARN"
      starts_with = ["arn:${local.partition}:s3:::svp-prd-media-${local.prd_id}-${var.region}/"]
    }
  }

  # CloudTrail checks trusted access when an organization trail is created or changed.
  depends_on = [aws_organizations_organization.this]
}
