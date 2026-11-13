# The copies of the stg and prd backups in an account of their own, so administrators of the env accounts cannot
# delete them; management still can, through the role this root applies with. Lives between sessions. Design notes:
# README.md.

data "aws_partition" "current" {}

# A member account may describe its organization; the key checks that it is the management account's.
data "aws_organizations_organization" "this" {}

locals {
  partition = data.aws_partition.current.partition

  # Governance lock of each copy vault. The range holds the retention the backup policy of the env gives its copies
  # (module org-policies: stg 2, prd 35 days); a copy job outside it fails.
  copy_vaults = {
    svp-stg-copy = {
      lock                  = { min_retention_days = 1, max_retention_days = 7 }
      copy_from_account_ids = [var.stg_account_id]
    }
    svp-prd-copy = {
      lock                  = { min_retention_days = 7, max_retention_days = 35 }
      copy_from_account_ids = [var.prd_account_id]
    }
  }
}

module "vaults" {
  source = "../modules/backup-vault"

  kms_key_arn = aws_kms_key.copy.arn
  vaults      = local.copy_vaults
}
