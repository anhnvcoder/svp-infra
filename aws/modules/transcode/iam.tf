# The role MediaConvert assumes to run the jobs of the queue: it reads the uploaded file and writes the HLS output,
# nothing else. The trust names this account and this queue, so no job of another account or queue can use it.
data "aws_iam_policy_document" "mediaconvert_trust" {
  statement {
    sid     = "MediaConvertJobsOfQueue"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["mediaconvert.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.queue_arn]
    }
  }
}

resource "aws_iam_role" "mediaconvert" {
  name               = local.role_name
  description        = "MediaConvert: jobs of queue ${local.name} read uploads/ and write media/"
  assume_role_policy = data.aws_iam_policy_document.mediaconvert_trust.json
}

# Uploads are encrypted with the env's uploads key (SSE-KMS), so reading the input also takes kms:Decrypt on that key;
# media uses SSE-S3 and needs no KMS permission to write.
data "aws_iam_policy_document" "mediaconvert" {
  statement {
    sid       = "ReadInput"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.uploads_bucket_arn}/uploads/*"]
  }

  statement {
    sid       = "DecryptInput"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.uploads_kms_key_arn]
  }

  statement {
    sid       = "WriteOutput"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${var.media_bucket_arn}/media/*"]
  }
}

# Inline: the policy names the buckets of this env and belongs to this role alone.
resource "aws_iam_role_policy" "mediaconvert" {
  name   = "s3"
  role   = aws_iam_role.mediaconvert.id
  policy = data.aws_iam_policy_document.mediaconvert.json
}

# What the bridge (media-worker mediaconvert) needs besides S3, which the media module grants: create, read and probe
# jobs, pass the role above to MediaConvert only, and consume the job state queue. The env root joins both documents in
# the policy of the Pod Identity role of media-worker.
data "aws_iam_policy_document" "bridge" {
  statement {
    sid       = "CreateJobs"
    effect    = "Allow"
    actions   = ["mediaconvert:CreateJob"]
    resources = [local.queue_arn]
  }

  # A job id is known only once the job exists.
  statement {
    sid       = "ReadJobs"
    effect    = "Allow"
    actions   = ["mediaconvert:GetJob"]
    resources = [local.jobs_arn]
  }

  # Probe has no resource type, so it takes no narrower resource than "*".
  statement {
    sid       = "ProbeInputs"
    effect    = "Allow"
    actions   = ["mediaconvert:Probe"]
    resources = ["*"]
  }

  statement {
    sid       = "PassMediaConvertRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["mediaconvert.amazonaws.com"]
    }
  }

  statement {
    sid       = "ConsumeJobStates"
    effect    = "Allow"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility"]
    resources = [local.events_arn]
  }
}
