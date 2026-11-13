# The default key policy: the account administers and uses the key through IAM, no other account or "*". ECR reads
# and writes with it through the grants it creates for each repository, so pushers and pullers need no KMS permission.
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

  # Without this key no image of the registry can be pulled again.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/svp-${var.env}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}
