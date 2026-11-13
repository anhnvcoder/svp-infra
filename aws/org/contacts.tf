# The SECURITY alternate contact of every account (CIS AWS Foundations Benchmark v5.0.0, 1.2): AWS writes there about
# a security issue of the account instead of only to its root email.
locals {
  # The management account sets its own contact without an account id: the Account Management API refuses its own id.
  contact_accounts = {
    management  = null
    stg         = aws_organizations_account.member["stg"].id
    prd         = aws_organizations_account.member["prd"].id
    log-archive = aws_organizations_account.log_archive.id
    security    = aws_organizations_account.security.id
    backup      = aws_organizations_account.backup.id
  }
}

resource "aws_account_alternate_contact" "security" {
  for_each = local.contact_accounts

  account_id             = each.value
  alternate_contact_type = "SECURITY"
  name                   = var.security_contact.name
  title                  = var.security_contact.title
  email_address          = var.security_contact.email_address
  phone_number           = var.security_contact.phone_number

  # A member account is reached through the trusted access of account.amazonaws.com.
  depends_on = [aws_organizations_organization.this]
}
