# Design notes: aws/modules/account-baseline/README.md.
locals {
  # Roles IAM Identity Center creates in this account for the permission set SvpAdmin. The role name ends in a random
  # suffix, so the policy matches it with a trailing wildcard, as the IAM Identity Center guide on referencing
  # permission sets in KMS key policies does. The path has no region when the Identity Center instance is in us-east-1
  # and the region otherwise; both forms are listed. Only IAM Identity Center can create roles under /aws-reserved/.
  admin_role_arn_patterns = [
    "arn:aws:iam::${var.account_id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_SvpAdmin_*",
    "arn:aws:iam::${var.account_id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_SvpAdmin_*",
  ]

  # The "key administrators" actions of the AWS KMS default key policy
  # (https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html): manage the key, never use it.
  key_admin_actions = [
    "kms:Create*",
    "kms:Describe*",
    "kms:Enable*",
    "kms:List*",
    "kms:Put*",
    "kms:Update*",
    "kms:Revoke*",
    "kms:Disable*",
    "kms:Get*",
    "kms:Delete*",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:ScheduleKeyDeletion",
    "kms:CancelKeyDeletion",
    "kms:RotateKeyOnDemand",
  ]

  # What the S3 backend needs on the key of the state (kms_key_id of the Terraform S3 backend: Encrypt, Decrypt,
  # GenerateDataKey), plus DescribeKey for the console and the CLI.
  key_use_actions = [
    "kms:Encrypt",
    "kms:Decrypt",
    "kms:ReEncrypt*",
    "kms:GenerateDataKey*",
    "kms:DescribeKey",
  ]
}

# Key policy of the state key. State holds outputs and resource attributes that a role allowed only to list or read the
# bucket should not see, so reading it takes kms:Decrypt, which only the SvpAdmin roles get (aws:PrincipalArn narrows
# the use; no statement names the principal "*"). The account administers the key without kms:Decrypt, so any admin of
# the account can still fix the key policy if the permission set is renamed or removed.
data "aws_iam_policy_document" "state_key" {
  statement {
    sid       = "AccountAdministersKey"
    effect    = "Allow"
    actions   = local.key_admin_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid       = "SvpAdminUsesKey"
    effect    = "Allow"
    actions   = local.key_use_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = local.admin_role_arn_patterns
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Terraform state of svp-${var.env} (bucket ${local.state_bucket})"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.state_key.json

  # Without this key the state in the bucket cannot be read. Removing both on purpose: aws/accounts/README.md.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/svp-tfstate"
  target_key_id = aws_kms_key.state.key_id
}
