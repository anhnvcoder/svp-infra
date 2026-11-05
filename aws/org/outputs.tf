output "organization_id" {
  description = "Id of the organization (o-...)."
  value       = aws_organizations_organization.this.id
}

output "stg_account_id" {
  description = "Id of the member account svp-stg, the value of SVP_AWS_STG_ACCOUNT_ID."
  value       = aws_organizations_account.member["stg"].id
}

output "prd_account_id" {
  description = "Id of the member account svp-prd, the value of SVP_AWS_PRD_ACCOUNT_ID."
  value       = aws_organizations_account.member["prd"].id
}
