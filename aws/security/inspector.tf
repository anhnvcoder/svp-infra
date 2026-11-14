# Amazon Inspector scans container images in ECR, and nothing else: nodes are replaced each session from a pinned EKS
# AMI and watched by GuardDuty Runtime Monitoring, and the lab runs no Lambda. Home region only, where the registries
# are. Findings reach Security Hub through its built-in integration. Design notes: aws/security/README.md.

resource "aws_inspector2_organization_configuration" "this" {
  # Accounts that join the organization later.
  auto_enable {
    ec2             = false
    ecr             = true
    lambda          = false
    lambda_code     = false
    code_repository = false
  }

  # Inspector turned off in the delegated administrator cannot change this any more, so destroy resets it first.
  depends_on = [aws_inspector2_enabler.security]
}

# Designating the delegated administrator turns every scan type on in this account. Importing that state makes the
# first apply an in-place update that turns the other types off; a create would wait for the whole account to turn
# off, which never happens while ECR stays on. The provider refuses this account and members in one enabler.
import {
  to = aws_inspector2_enabler.security
  id = "${var.security_account_id}-ECR"
}

resource "aws_inspector2_enabler" "security" {
  account_ids    = [var.security_account_id]
  resource_types = ["ECR"]
}

locals {
  # Every active member already in the organization whose inspector_ecr flag is not off; the closed accounts that wait
  # to leave it are SUSPENDED.
  inspector_member_ids = sort([
    for account in data.aws_organizations_organization.this.non_master_accounts : account.id
    if account.state == "ACTIVE" && account.id != var.security_account_id && !contains(local.inspector_off_ids, account.id)
  ])
}

# Inspector turns off in the delegated administrator only once no member is associated with it, so destroy turns the
# members' scans off, then disassociates them, then turns this account off.
resource "aws_inspector2_member_association" "members" {
  for_each = toset(local.inspector_member_ids)

  account_id = each.key

  depends_on = [aws_inspector2_enabler.security]
}

resource "aws_inspector2_enabler" "members" {
  account_ids    = local.inspector_member_ids
  resource_types = ["ECR"]

  depends_on = [aws_inspector2_member_association.members]
}
