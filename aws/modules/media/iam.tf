# Policies of the two services that use the buckets, as JSON for the roles their Pod Identity associations assume.
# video-service gets what its user has on the local object store plus s3:ListBucket on the uploads bucket (ListUploads):
# S3 answers a HEAD or GET of a missing key with 403, not 404, when the caller may not list the bucket, and the
# service would take "not there" for an outage.

# ListUploads carries no s3:prefix condition: besides uploads/<id> the bucket holds only GuardDuty's validation object,
# and S3 does not document that its 403-or-404 decision honours one. A listing shows video ids, which the service
# already knows, and that object. s3:PutObject also covers multipart calls and conditional If-None-Match writes; neither
# service may abort a multipart upload (the lifecycle rules do).

# video-service signs upload forms for uploads/<id>, checks and deletes the uploaded file, and deletes the media of a
# video it removes (which needs a listing of that video's prefix).
data "aws_iam_policy_document" "video_service" {
  statement {
    sid       = "Uploads"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.this["uploads"].arn}/uploads/*"]
  }

  statement {
    sid       = "ListUploads"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this["uploads"].arn]
  }

  statement {
    sid       = "ListMedia"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this["media"].arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["media/*"]
    }
  }

  statement {
    sid       = "DeleteMedia"
    effect    = "Allow"
    actions   = ["s3:DeleteObject"]
    resources = ["${aws_s3_bucket.this["media"].arn}/media/*"]
  }
}

# On AWS media-worker runs as the MediaConvert bridge. MediaConvert's Probe reads the upload with the caller's rights;
# the bridge copies the job's output onto itself, writes the master and the job records under transcode-jobs/, and
# lists both prefixes to learn whether a key exists. Its MediaConvert, SQS and PassRole rights come from elsewhere.
# Design notes: aws/modules/media/README.md.
data "aws_iam_policy_document" "media_worker" {
  statement {
    sid       = "ReadUploads"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arns["uploads"]}/uploads/*"]
  }

  statement {
    sid     = "WriteMedia"
    effect  = "Allow"
    actions = ["s3:PutObject", "s3:GetObject"]
    resources = [
      "${local.bucket_arns["media"]}/media/*",
      "${local.bucket_arns["media"]}/transcode-jobs/*",
    ]
  }

  statement {
    sid       = "ListMedia"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arns["media"]]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["media/*", "transcode-jobs/*"]
    }
  }
}
