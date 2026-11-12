# Customer managed key that encrypts new EBS volumes of svp-stg and svp-prd in the home region, the only accounts and
# region that run EC2. The key policy is that of the AWS managed key aws/ebs: any principal of the account may use it
# through EC2 of the home region, so node groups (the AutoScaling service-linked role), Karpenter and the bastion need
# no IAM change. Design notes: aws/baseline/README.md.

locals {
  # Built from its parts rather than read from the key: a template is known to be non-null before the key exists, so
  # the module can decide at plan time to set the default key (the arn attribute would leave that count unknown).
  ebs_key_arns = {
    stg = "arn:${local.partition}:kms:${var.region}:${var.stg_account_id}:key/${aws_kms_key.stg_ebs.key_id}"
    prd = "arn:${local.partition}:kms:${var.region}:${var.prd_account_id}:key/${aws_kms_key.prd_ebs.key_id}"
  }

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
