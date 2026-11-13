resource "aws_kms_key" "copy" {
  description = "Encrypts the copies of the stg and prd recovery points in the vaults svp-stg-copy and svp-prd-copy"
  # The longest waiting period: a key scheduled for deletion by mistake can be cancelled for 30 days, after which
  # every copy it encrypted is unreadable.
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.key.json

  lifecycle {
    prevent_destroy = true

    # The backup account must belong to the organization of the management account, or no backup policy copies here.
    precondition {
      condition     = data.aws_organizations_organization.this.master_account_id == var.account_id
      error_message = "account_id is not the management account of the organization of backup_account_id (TF_VAR_account_id from SVP_AWS_MGMT_ACCOUNT_ID, TF_VAR_backup_account_id from SVP_AWS_BACKUP_ACCOUNT_ID)."
    }
  }
}

resource "aws_kms_alias" "copy" {
  name          = "alias/svp-backup-copy"
  target_key_id = aws_kms_key.copy.key_id
}

# The default statement only: AWS Backup re-encrypts a copy with the key of the vault it lands in, on behalf of this
# account, so no other account needs this key. The env accounts share their source keys instead.
data "aws_iam_policy_document" "key" {
  statement {
    sid       = "EnableIamPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${var.backup_account_id}:root"]
    }
  }
}
