# The organization already exists (the management account created it before this root): the first apply imports it
# (README.md), so these arguments match what it has and only add to it. Never destroyed: deleting an organization needs
# every member account gone first, and the members, SCPs and Identity Center hang on it.
resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # sso.amazonaws.com was on before this root; cloudtrail.amazonaws.com is the trusted access an organization trail
  # needs. A principal missing here would be turned off by the next apply.
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "sso.amazonaws.com",
  ]

  # SERVICE_CONTROL_POLICY for org-policies. RESOURCE_CONTROL_POLICY was on before this root and stays: dropping it
  # here would turn it off.
  enabled_policy_types = [
    "RESOURCE_CONTROL_POLICY",
    "SERVICE_CONTROL_POLICY",
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.this.roots[0].id
}

locals {
  member_envs = toset(["stg", "prd"])
}

# One member account per env. Organizations creates OrganizationAccountAccessRole in each (role_name left at its
# default), which the management account assumes; IAM inside the member accounts is not managed here.
resource "aws_organizations_account" "member" {
  for_each = local.member_envs

  name      = "svp-${each.key}"
  email     = var.account_emails[each.key]
  parent_id = aws_organizations_organizational_unit.workloads.id

  # Closing an account is a deliberate step of its own (README.md), never a side effect of a destroy.
  close_on_deletion = false

  lifecycle {
    prevent_destroy = true

    # Set only when the account is created: the Organizations API never returns them, so after an import or a change
    # they would show a difference or force a new account (aws_organizations_account, provider documentation).
    ignore_changes = [role_name, iam_user_access_to_billing]
  }
}

module "org_policies" {
  source = "../modules/org-policies"

  target_id = aws_organizations_organizational_unit.workloads.id

  # Policies of a type the organization has not enabled are refused.
  depends_on = [aws_organizations_organization.this]
}
