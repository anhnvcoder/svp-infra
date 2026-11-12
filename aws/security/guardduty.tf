################################################################################
# Delegated administrator
################################################################################

# GuardDuty turns itself on in the delegated administrator account of each region when aws/org designates it, so the
# detector is read here, not created: creating it again would fail.
data "aws_guardduty_detector" "this" {
  for_each = local.regions

  region = each.key
}

resource "aws_guardduty_organization_configuration" "this" {
  for_each = local.regions

  region      = each.key
  detector_id = data.aws_guardduty_detector.this[each.key].id

  # Every account, those that join later and the delegated administrator included; the management account joins
  # through aws_guardduty_member below.
  auto_enable_organization_members = "ALL"
}

locals {
  # The protection plans of every account; agents of Runtime Monitoring stay managed in Terraform (eks add-on and
  # network endpoint), since GuardDuty would create an endpoint and a security group outside any state.
  guardduty_features = {
    S3_DATA_EVENTS         = []
    EKS_AUDIT_LOGS         = []
    EBS_MALWARE_PROTECTION = []
    RDS_LOGIN_EVENTS       = []
    LAMBDA_NETWORK_LOGS    = []
    RUNTIME_MONITORING     = ["EKS_ADDON_MANAGEMENT", "ECS_FARGATE_AGENT_MANAGEMENT", "EC2_AGENT_MANAGEMENT"]
  }

  guardduty_region_features = {
    for pair in setproduct(local.regions, keys(local.guardduty_features)) : "${pair[0]}/${pair[1]}" => {
      region     = pair[0]
      name       = pair[1]
      additional = local.guardduty_features[pair[1]]
    }
  }
}

resource "aws_guardduty_organization_configuration_feature" "this" {
  for_each = local.guardduty_region_features

  region      = each.value.region
  detector_id = data.aws_guardduty_detector.this[each.value.region].id
  name        = each.value.name
  auto_enable = "ALL"

  dynamic "additional_configuration" {
    for_each = each.value.additional

    content {
      name        = additional_configuration.value
      auto_enable = "NONE"
    }
  }

  depends_on = [aws_guardduty_organization_configuration.this]
}

# Findings of both detectors go to the GuardDuty bucket of the log archive, in the home region.
resource "aws_guardduty_publishing_destination" "this" {
  for_each = local.regions

  region           = each.key
  detector_id      = data.aws_guardduty_detector.this[each.key].id
  destination_type = "S3"
  destination_arn  = "arn:aws:s3:::svp-guardduty-${var.log_archive_account_id}-${var.region}"
  kms_key_arn      = data.aws_kms_alias.log_archive.target_key_arn
}

################################################################################
# Management account
################################################################################

# Auto-enable leaves the management account out: it must have GuardDuty on before the delegated administrator adds it.
resource "aws_guardduty_detector" "management" {
  for_each = local.regions
  provider = aws.management

  region = each.key
  enable = true
}

resource "aws_guardduty_member" "management" {
  for_each = local.regions

  region      = each.key
  detector_id = data.aws_guardduty_detector.this[each.key].id
  account_id  = var.account_id
  email       = data.aws_organizations_organization.this.master_account_email

  # An organization account needs no invitation; the provider reads its Enabled relationship back as invite = true.
  lifecycle {
    ignore_changes = [invite]
  }

  depends_on = [aws_guardduty_detector.management, aws_guardduty_organization_configuration.this]
}
