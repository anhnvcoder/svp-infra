# AWS Backup vaults encrypted with a key the caller owns, each with an optional governance lock and an optional access
# policy that lets other accounts copy into it. Design notes: aws/modules/backup-vault/README.md.

data "aws_partition" "current" {}

locals {
  locks    = { for name, v in var.vaults : name => v.lock if v.lock != null }
  copy_ins = { for name, v in var.vaults : name => v.copy_from_account_ids if length(v.copy_from_account_ids) > 0 }
}

resource "aws_backup_vault" "this" {
  for_each = var.vaults

  name        = each.key
  kms_key_arn = var.kms_key_arn
}

# Governance mode: without changeable_for_days the lock never turns into compliance mode, so a principal with
# backup:DeleteBackupVaultLockConfiguration can still remove it when the lab is taken down.
resource "aws_backup_vault_lock_configuration" "this" {
  for_each = local.locks

  backup_vault_name  = aws_backup_vault.this[each.key].name
  min_retention_days = each.value.min_retention_days
  max_retention_days = each.value.max_retention_days
}

# Only copying in is granted: AWS Backup rejects every other action from another account whatever the vault policy says.
data "aws_iam_policy_document" "access" {
  for_each = local.copy_ins

  statement {
    sid       = "CopyIntoVaultFromAccounts"
    effect    = "Allow"
    actions   = ["backup:CopyIntoBackupVault"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [for account in each.value : "arn:${data.aws_partition.current.partition}:iam::${account}:root"]
    }
  }
}

resource "aws_backup_vault_policy" "this" {
  for_each = local.copy_ins

  backup_vault_name = aws_backup_vault.this[each.key].name
  policy            = data.aws_iam_policy_document.access[each.key].json
}
