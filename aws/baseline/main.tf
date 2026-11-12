# The security baseline of the five accounts of the organization, applied from the management account. What differs
# between accounts is data in local.accounts; each account gets one call of the security-baseline module.
# Design notes: aws/baseline/README.md.

data "aws_partition" "current" {
  provider = aws.mgmt
}

# The key/<id> form: the delivery channels store the key ARN they are given, so an alias ARN never gives a clean plan.
data "aws_kms_alias" "log_archive" {
  provider = aws.log_archive
  name     = "alias/svp-log-archive"
}

locals {
  partition = data.aws_partition.current.partition

  # Derived from the account ids, as aws/log-archive and aws/security name them, without reading their state.
  config_bucket_name     = "svp-config-${var.log_archive_account_id}-${var.region}"
  security_event_bus_arn = "arn:${local.partition}:events:${var.region}:${var.security_account_id}:event-bus/svp-security-events"

  # ebs_kms_key_arn: null keeps aws/ebs. admin_events: off where every session creates dozens of roles, keys and
  # buckets. organization_events, three sign-in regions and the Identity Center rule: management only, the account
  # that records those events and is not held to the region policy.
  accounts = {
    mgmt = {
      ebs_kms_key_arn        = null
      admin_events           = true
      organization_events    = true
      root_signin_regions    = ["us-east-1", "us-east-2", "us-west-2"]
      identity_center_region = var.sso_region
    }
    log-archive = {
      ebs_kms_key_arn        = null
      admin_events           = true
      organization_events    = false
      root_signin_regions    = ["us-east-1"]
      identity_center_region = null
    }
    security = {
      ebs_kms_key_arn        = null
      admin_events           = true
      organization_events    = false
      root_signin_regions    = ["us-east-1"]
      identity_center_region = null
    }
    stg = {
      ebs_kms_key_arn        = local.ebs_key_arns.stg
      admin_events           = false
      organization_events    = false
      root_signin_regions    = ["us-east-1"]
      identity_center_region = null
    }
    prd = {
      ebs_kms_key_arn        = local.ebs_key_arns.prd
      admin_events           = false
      organization_events    = false
      root_signin_regions    = ["us-east-1"]
      identity_center_region = null
    }
  }
}

module "mgmt" {
  source    = "../modules/security-baseline"
  providers = { aws = aws.mgmt }

  config_bucket_name     = local.config_bucket_name
  log_archive_key_arn    = data.aws_kms_alias.log_archive.target_key_arn
  security_event_bus_arn = local.security_event_bus_arn
  ebs_kms_key_arn        = local.accounts.mgmt.ebs_kms_key_arn
  admin_events           = local.accounts.mgmt.admin_events
  organization_events    = local.accounts.mgmt.organization_events
  root_signin_regions    = local.accounts.mgmt.root_signin_regions
  identity_center_region = local.accounts.mgmt.identity_center_region
}

module "log_archive" {
  source    = "../modules/security-baseline"
  providers = { aws = aws.log_archive }

  config_bucket_name     = local.config_bucket_name
  log_archive_key_arn    = data.aws_kms_alias.log_archive.target_key_arn
  security_event_bus_arn = local.security_event_bus_arn
  ebs_kms_key_arn        = local.accounts.log-archive.ebs_kms_key_arn
  admin_events           = local.accounts.log-archive.admin_events
  organization_events    = local.accounts.log-archive.organization_events
  root_signin_regions    = local.accounts.log-archive.root_signin_regions
  identity_center_region = local.accounts.log-archive.identity_center_region
}

module "security" {
  source    = "../modules/security-baseline"
  providers = { aws = aws.security }

  config_bucket_name     = local.config_bucket_name
  log_archive_key_arn    = data.aws_kms_alias.log_archive.target_key_arn
  security_event_bus_arn = local.security_event_bus_arn
  ebs_kms_key_arn        = local.accounts.security.ebs_kms_key_arn
  admin_events           = local.accounts.security.admin_events
  organization_events    = local.accounts.security.organization_events
  root_signin_regions    = local.accounts.security.root_signin_regions
  identity_center_region = local.accounts.security.identity_center_region
}

module "stg" {
  source    = "../modules/security-baseline"
  providers = { aws = aws.stg }

  config_bucket_name     = local.config_bucket_name
  log_archive_key_arn    = data.aws_kms_alias.log_archive.target_key_arn
  security_event_bus_arn = local.security_event_bus_arn
  ebs_kms_key_arn        = local.accounts.stg.ebs_kms_key_arn
  admin_events           = local.accounts.stg.admin_events
  organization_events    = local.accounts.stg.organization_events
  root_signin_regions    = local.accounts.stg.root_signin_regions
  identity_center_region = local.accounts.stg.identity_center_region
}

module "prd" {
  source    = "../modules/security-baseline"
  providers = { aws = aws.prd }

  config_bucket_name     = local.config_bucket_name
  log_archive_key_arn    = data.aws_kms_alias.log_archive.target_key_arn
  security_event_bus_arn = local.security_event_bus_arn
  ebs_kms_key_arn        = local.accounts.prd.ebs_kms_key_arn
  admin_events           = local.accounts.prd.admin_events
  organization_events    = local.accounts.prd.organization_events
  root_signin_regions    = local.accounts.prd.root_signin_regions
  identity_center_region = local.accounts.prd.identity_center_region
}
