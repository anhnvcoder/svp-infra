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

module "paid_features" {
  source = "../modules/paid-features"

  features = jsondecode(file("${path.root}/../paid-features.json"))
}

locals {
  # Account key of aws/paid-features.json to account id: the member svp-<key>, and mgmt, which is not a member.
  # A closed account (SUSPENDED) has no key, so a flag set for it switches nothing.
  account_ids = merge(
    {
      for account in data.aws_organizations_organization.this.non_master_accounts : trimprefix(account.name, "svp-") => account.id
      if account.state == "ACTIVE" && startswith(account.name, "svp-")
    },
    { mgmt = var.account_id },
  )

  inspector_off_ids    = [for k in module.paid_features.off_accounts.inspector_ecr : local.account_ids[k] if contains(keys(local.account_ids), k)]
  security_hub_off_ids = sort([for k in module.paid_features.off_accounts.security_hub : local.account_ids[k] if contains(keys(local.account_ids), k)])
}

# The key/<id> form: GuardDuty stores the key ARN it is given, so an alias ARN would never match what the API returns.
data "aws_kms_alias" "log_archive" {
  provider = aws.log_archive
  name     = "alias/svp-log-archive"
}
