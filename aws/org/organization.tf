# The organization already exists (the management account created it before this root): the first apply imports it
# (README.md), so these arguments match what it has and only add to it. Never destroyed: deleting an organization needs
# every member account gone first, and the members, policies and Identity Center hang on it.
resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # A principal missing here would be turned off by the next apply, those the services enable themselves included:
  # sso and cloudtrail were on before; account for the alternate contacts, iam for centralized root access, ec2 for the
  # declarative policy, and the detection services delegated-admins.tf registers. Design notes: README.md.
  aws_service_access_principals = [
    "access-analyzer.amazonaws.com",
    "account.amazonaws.com",
    "cloudtrail.amazonaws.com",
    "config-multiaccountsetup.amazonaws.com",
    "config.amazonaws.com",
    "ec2.amazonaws.com",
    "guardduty.amazonaws.com",
    "iam.amazonaws.com",
    "inspector2.amazonaws.com",
    "malware-protection.guardduty.amazonaws.com",
    "securityhub.amazonaws.com",
    "sso.amazonaws.com",
  ]

  # RESOURCE_CONTROL_POLICY was on before this root and stays: dropping a type here would turn it off.
  enabled_policy_types = [
    "DECLARATIVE_POLICY_EC2",
    "RESOURCE_CONTROL_POLICY",
    "SERVICE_CONTROL_POLICY",
    "TAG_POLICY",
  ]

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  root_id = aws_organizations_organization.this.roots[0].id
}

# The organizational units of the AWS Security Reference Architecture: Security holds the log archive and the security
# tooling account, Workloads one child per environment class so production gets guardrails of its own.
resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = local.root_id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = local.root_id
}

resource "aws_organizations_organizational_unit" "prod" {
  name      = "Prod"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "nonprod" {
  name      = "NonProd"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

locals {
  member_envs = toset(["stg", "prd"])

  # A change of parent moves the account in place (MoveAccount); the account itself is never created again.
  env_ou = {
    stg = aws_organizations_organizational_unit.nonprod.id
    prd = aws_organizations_organizational_unit.prod.id
  }
}

# One member account per env. Organizations creates OrganizationAccountAccessRole in each (role_name left at its
# default), which the management account assumes; IAM inside the member accounts is not managed here.
resource "aws_organizations_account" "member" {
  for_each = local.member_envs

  name      = "svp-${each.key}"
  email     = var.account_emails[each.key]
  parent_id = local.env_ou[each.key]

  # Closing an account is a deliberate step of its own (README.md), never a side effect of a destroy.
  close_on_deletion = false

  lifecycle {
    prevent_destroy = true

    # Set only when the account is created: the Organizations API never returns them, so after an import or a change
    # they would show a difference or force a new account (aws_organizations_account, provider documentation).
    ignore_changes = [role_name, iam_user_access_to_billing]
  }
}

# Log Archive: the organization's logs, out of reach of the workload administrators. Reached only from the management
# account through OrganizationAccountAccessRole.
resource "aws_organizations_account" "log_archive" {
  name      = "svp-log-archive"
  email     = var.account_emails["log-archive"]
  parent_id = aws_organizations_organizational_unit.security.id

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, iam_user_access_to_billing]
  }
}

# Security Tooling: delegated administrator of the detection services (delegated-admins.tf).
resource "aws_organizations_account" "security" {
  name      = "svp-security"
  email     = var.account_emails["security"]
  parent_id = aws_organizations_organizational_unit.security.id

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, iam_user_access_to_billing]
  }
}

module "org_policies" {
  source = "../modules/org-policies"

  root_id         = local.root_id
  prod_ou_id      = aws_organizations_organizational_unit.prod.id
  organization_id = aws_organizations_organization.this.id

  # Policies of a type the organization has not enabled are refused.
  depends_on = [aws_organizations_organization.this]
}
