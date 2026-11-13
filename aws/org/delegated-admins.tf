# svp-security administers the detection services of the whole organization (AWS Security Reference Architecture:
# Security Tooling account), so their configuration and findings live outside the management account and out of reach
# of the workload administrators. The services themselves are configured from that account, in aws/security.
# Each registration needs the trusted access of its service on the organization first.

locals {
  # GuardDuty keeps one administrator per region: the two regions the member accounts may use.
  guardduty_regions = toset(["ap-southeast-1", "us-east-1"])

  # Services registered through Organizations itself. Config has two principals: aggregators and organization rules.
  delegated_services = toset([
    "access-analyzer.amazonaws.com",
    "config-multiaccountsetup.amazonaws.com",
    "config.amazonaws.com",
  ])
}

resource "aws_guardduty_organization_admin_account" "security" {
  for_each = local.guardduty_regions

  region           = each.key
  admin_account_id = aws_organizations_account.security.id

  depends_on = [aws_organizations_organization.this]
}

# Central configuration of Security Hub CSPM is run by the administrator of the home region, which reaches the linked
# regions from there; no registration in us-east-1.
resource "aws_securityhub_organization_admin_account" "security" {
  admin_account_id = aws_organizations_account.security.id

  depends_on = [aws_organizations_organization.this]
}

# Inspector scans the images of the workload registries, which live in the home region alone.
resource "aws_inspector2_delegated_admin_account" "security" {
  account_id = aws_organizations_account.security.id

  depends_on = [aws_organizations_organization.this]
}

resource "aws_organizations_delegated_administrator" "security" {
  for_each = local.delegated_services

  account_id        = aws_organizations_account.security.id
  service_principal = each.key

  depends_on = [aws_organizations_organization.this]
}
