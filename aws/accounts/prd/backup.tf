# The vault the backup policy of the organization writes into, its key, the opt-in of the account and the role AWS
# Backup assumes for every job of the account. Recovery points here are removed at the end of each session; the copies
# that outlive the account's own data sit in the locked vaults of svp-backup. Design notes: aws/accounts/README.md.

data "aws_partition" "backup" {}

locals {
  backup_account_root = "arn:${data.aws_partition.backup.partition}:iam::${var.backup_account_id}:root"

  # Kept as AWS publishes them: AWS updates these policies as the services they cover change.
  backup_role_policies = toset([
    "AWSBackupServiceRolePolicyForBackup",
    "AWSBackupServiceRolePolicyForRestores",
    "AWSBackupServiceRolePolicyForS3Backup",
    "AWSBackupServiceRolePolicyForS3Restore",
  ])
}

# No prevent_destroy: the vault keeps no recovery point between sessions, so losing the key loses nothing the copies
# in svp-backup do not hold, re-encrypted with their own key.
resource "aws_kms_key" "backup" {
  description             = "AWS Backup vault svp-${local.env}: recovery points before their copy to svp-backup"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.backup_key.json
}

resource "aws_kms_alias" "backup" {
  name          = "alias/svp-${local.env}-backup"
  target_key_id = aws_kms_key.backup.key_id
}

# The backup account decrypts a recovery point of this vault to copy it into its own vault. CreateGrant only for a
# grant AWS Backup makes on a vault: the encryption context names the vault.
data "aws_iam_policy_document" "backup_key" {
  statement {
    sid       = "EnableIamUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.backup.partition}:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid       = "BackupAccountUseForCopy"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.backup_account_root]
    }
  }

  statement {
    sid       = "BackupAccountGrantForCopy"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.backup_account_root]
    }

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:EncryptionContextKeys"
      values   = ["aws:backup:backup-vault"]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["backup.*.amazonaws.com"]
    }
  }
}

# No vault lock: the end of every session deletes the recovery points of this vault once they are copied.
module "backup_vault" {
  source = "../../modules/backup-vault"

  kms_key_arn = aws_kms_key.backup.arn
  vaults = {
    "svp-${local.env}" = {}
  }
}

# On-demand and restore jobs of this account follow its own opt-in. The resource writes the whole map, so it lists
# every type AWS Backup supports in the region, each on as AWS sets it for an account that starts using AWS Backup.
resource "aws_backup_region_settings" "this" {
  resource_type_opt_in_preference = {
    "Aurora"                 = true
    "CloudFormation"         = true
    "DSQL"                   = true
    "DocumentDB"             = true
    "DynamoDB"               = true
    "EBS"                    = true
    "EC2"                    = true
    "EFS"                    = true
    "EKS"                    = true
    "FSx"                    = true
    "Neptune"                = true
    "RDS"                    = true
    "Redshift"               = true
    "Redshift Serverless"    = true
    "S3"                     = true
    "SAP HANA on Amazon EC2" = true
    "Storage Gateway"        = true
    "VirtualMachine"         = true
  }
}

# Only AWS Backup acting for this account may assume the role: the backup policy names it in every account it covers.
data "aws_iam_policy_document" "backup_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "svp-${local.env}-backup"
  description        = "Role AWS Backup assumes for the backup, copy and restore jobs of svp-${local.env}"
  assume_role_policy = data.aws_iam_policy_document.backup_trust.json
}

# Looked up by name: the AWS managed policies of AWS Backup do not all sit under the same path.
data "aws_iam_policy" "backup" {
  for_each = local.backup_role_policies

  name = each.key
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = local.backup_role_policies

  role       = aws_iam_role.backup.name
  policy_arn = data.aws_iam_policy.backup[each.key].arn
}
