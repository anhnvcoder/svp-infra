# No repository is encrypted with this key any more (AES256 instead). It stays until no repository the pull through
# cache made before the switch uses it: deleting the key would make their images unreadable. Default key policy: the
# account administers and uses it through IAM, no other account or "*".
data "aws_iam_policy_document" "ecr_key" {
  statement {
    sid       = "EnableIamUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "ecr" {
  description             = "ECR repositories of svp-${var.env}: releases and pull through cache"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.ecr_key.json

  # Without this key no image of a repository still encrypted with it can be pulled again.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/svp-${var.env}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}
