# Policies of the two services that use the buckets, as JSON for the roles their Pod Identity associations assume.
# video-service gets what its user has on the local object store plus s3:ListBucket on the uploads bucket (ListUploads):
# S3 answers a HEAD or GET of a missing key with 403, not 404, when the caller may not list the bucket, and the
# service would take "not there" for an outage.

# ListUploads carries no s3:prefix condition: besides uploads/<id> the bucket holds only GuardDuty's validation object,
# and S3 does not document that its 403-or-404 decision honours one. A listing shows video ids, which the service
# already knows, and that object. s3:PutObject also covers multipart calls and conditional If-None-Match writes; neither
# service may abort a multipart upload (the lifecycle rules do).

locals {
  # Every object of a video lives under one of these (normal, premium, public preview of a premium video).
  media_prefixes = ["media/", "premium/", "preview/"]
}

# video-service signs upload forms for uploads/<id>, checks and deletes the uploaded file, deletes the media of a
# video it removes under each of the three media prefixes (which needs a listing of that video's prefix), and reads
# the playlists of premium/ that it filters and signs.
data "aws_iam_policy_document" "video_service" {
  statement {
    sid       = "Uploads"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arns["uploads"]}/uploads/*"]
  }

  # S3 makes the data key of an upload with the rights of the form's signer. The service only heads and deletes
  # uploads, which do not use the key, so it needs no kms:Decrypt.
  statement {
    sid       = "EncryptUploads"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey"]
    resources = [aws_kms_key.uploads.arn]
  }

  statement {
    sid       = "ListUploads"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arns["uploads"]]
  }

  statement {
    sid       = "ListMedia"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arns["media"]]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [for p in local.media_prefixes : "${p}*"]
    }
  }

  statement {
    sid       = "DeleteMedia"
    effect    = "Allow"
    actions   = ["s3:DeleteObject"]
    resources = [for p in local.media_prefixes : "${local.bucket_arns["media"]}/${p}*"]
  }

  statement {
    sid       = "ReadPremium"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arns["media"]}/premium/*"]
  }
}

# On AWS media-worker runs as the MediaConvert bridge. MediaConvert's Probe reads the upload with the caller's rights;
# the bridge copies the job's output onto itself and a premium video's preview to preview/, writes the masters and the
# job records under transcode-jobs/, and lists its prefixes to learn whether a key exists. Its MediaConvert, SQS and
# PassRole rights come from elsewhere. Design notes: docs/handbook/12-media-edge.md.
data "aws_iam_policy_document" "media_worker" {
  statement {
    sid       = "ReadUploads"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arns["uploads"]}/uploads/*"]
  }

  statement {
    sid       = "DecryptUploads"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.uploads.arn]
  }

  statement {
    sid       = "WriteMedia"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = [for p in concat(local.media_prefixes, ["transcode-jobs/"]) : "${local.bucket_arns["media"]}/${p}*"]
  }

  statement {
    sid       = "ListMedia"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arns["media"]]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [for p in concat(local.media_prefixes, ["transcode-jobs/"]) : "${p}*"]
    }
  }
}
