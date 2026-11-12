# Detection services of the organization, run by the Security Tooling account as delegated administrator, and the path
# that turns security events and severe findings into email. Design notes: aws/security/README.md.

locals {
  # The home region and us-east-1 (global services, CloudFront WAF); the region service control policy denies every
  # other region to the member accounts, so the detection services run in these two only.
  regions = toset([var.region, "us-east-1"])

  runbook_url = "https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/security-alert.md"
}

# Read through the management account: a member account cannot list the roots of the organization.
data "aws_organizations_organization" "this" {
  provider = aws.management
}

# The key/<id> form: GuardDuty stores the key ARN it is given, so an alias ARN would never match what the API returns.
data "aws_kms_alias" "log_archive" {
  provider = aws.log_archive
  name     = "alias/svp-log-archive"
}
