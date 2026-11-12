# Security baseline of one account: S3 Block Public Access of the account, EBS encryption by default, AWS Config
# recording, and the rules that forward security events to the Security Tooling account. One aws provider in the home
# region; resources of the other regions name theirs with the region argument. Design notes:
# aws/modules/security-baseline/README.md.

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  home_region = data.aws_region.current.region
  # IAM and Organizations record their CloudTrail events in us-east-1, whatever region the caller works in.
  global_region = "us-east-1"
  regions       = toset([local.home_region, local.global_region])
}

# Account-wide setting, not regional: it covers every bucket and access point of the account.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_ebs_encryption_by_default" "this" {
  for_each = local.regions

  region  = each.key
  enabled = true
}

# Without this resource EC2 uses aws/ebs; destroying it sets the default back to aws/ebs.
resource "aws_ebs_default_kms_key" "this" {
  count = var.ebs_kms_key_arn == null ? 0 : 1

  region  = local.home_region
  key_arn = var.ebs_kms_key_arn

  lifecycle {
    precondition {
      condition     = split(":", var.ebs_kms_key_arn)[3] == local.home_region
      error_message = "ebs_kms_key_arn must be a key of the home region: EC2 only takes a default key of its own region."
    }
  }
}
