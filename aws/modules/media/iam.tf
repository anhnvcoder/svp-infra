# Policies of the two services that use the buckets, as JSON for the roles their Pod Identity associations assume.
# They grant what each service's user has on the local object store, per prefix, plus s3:ListBucket on the uploads
# bucket (ListUploads): S3 answers a HEAD or GET of a missing key with 403, not 404, when the caller may not list the
# bucket, and both services would take "not there" for an outage.

# ListUploads carries no s3:prefix condition: besides uploads/<id> the bucket holds only GuardDuty's validation object,
# and S3 does not document that its 403-or-404 decision honours one. A listing shows video ids, which both services
# already know, and that object. s3:PutObject also covers multipart calls and conditional If-None-Match writes; neither
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

# media-worker reads the uploaded file and writes the HLS output; it reads and lists media/ to find out whether a
# version is already there before it transcodes again.
data "aws_iam_policy_document" "media_worker" {
  statement {
    sid       = "ReadUploads"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["uploads"].arn}/uploads/*"]
  }

  statement {
    sid       = "ListUploads"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this["uploads"].arn]
  }

  statement {
    sid       = "WriteMedia"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.this["media"].arn}/media/*"]
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
}
