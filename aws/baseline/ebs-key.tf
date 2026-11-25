# Former default key of new EBS volumes of svp-stg and svp-prd in the home region; EC2 now uses aws/ebs there too.
# The keys stay until no volume or snapshot is encrypted with them: deleting one makes those unreadable. The key policy
# is that of aws/ebs: any principal of the account may use it through EC2 of the home region.
# Design notes: docs/handbook/06-baseline.md.

locals {
  # Statements of the key policy of aws/ebs, one policy per account.
  ebs_key_policies = {
    for env, id in { stg = var.stg_account_id, prd = var.prd_account_id } : env => jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid       = "EnableIamPermissions"
          Effect    = "Allow"
          Principal = { AWS = "arn:${local.partition}:iam::${id}:root" }
          Action    = "kms:*"
          Resource  = "*"
        },
        {
          Sid       = "AllowEc2UseForAccount"
          Effect    = "Allow"
          Principal = { AWS = "*" }
          Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:CreateGrant", "kms:DescribeKey"]
          Resource  = "*"
          Condition = {
            StringEquals = {
              "kms:CallerAccount" = id
              "kms:ViaService"    = "ec2.${var.region}.amazonaws.com"
            }
          }
        },
      ]
    })
  }
}

# The Stack=security-baseline tag of default_tags and the alias name are what the baseline service control policy
# matches to keep every other principal from disabling, deleting, re-tagging or re-pointing these keys.
resource "aws_kms_key" "stg_ebs" {
  provider = aws.stg

  description = "Default encryption key of new EBS volumes of svp-stg in ${var.region}"
  # The longest waiting period: every volume and snapshot encrypted with the key is unreadable once it is deleted.
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = local.ebs_key_policies.stg
}

resource "aws_kms_alias" "stg_ebs" {
  provider = aws.stg

  name          = "alias/svp-ebs"
  target_key_id = aws_kms_key.stg_ebs.key_id
}

resource "aws_kms_key" "prd_ebs" {
  provider = aws.prd

  description             = "Default encryption key of new EBS volumes of svp-prd in ${var.region}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = local.ebs_key_policies.prd
}

resource "aws_kms_alias" "prd_ebs" {
  provider = aws.prd

  name          = "alias/svp-ebs"
  target_key_id = aws_kms_key.prd_ebs.key_id
}
