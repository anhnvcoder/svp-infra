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

output "log_archive_account_id" {
  description = "Id of the member account svp-log-archive, the value of SVP_AWS_LOG_ACCOUNT_ID."
  value       = aws_organizations_account.log_archive.id
}

output "security_account_id" {
  description = "Id of the member account svp-security, the value of SVP_AWS_SECURITY_ACCOUNT_ID."
  value       = aws_organizations_account.security.id
}

output "backup_account_id" {
  description = "Id of the member account svp-backup, the value of SVP_AWS_BACKUP_ACCOUNT_ID."
  value       = aws_organizations_account.backup.id
}

output "root_id" {
  description = "Id of the root of the organization (r-...), where every policy but the production guardrails is attached."
  value       = local.root_id
}

output "organizational_unit_ids" {
  description = "Id of each organizational unit of this root, by name (Security, Workloads, Prod, NonProd)."
  value = {
    Security  = aws_organizations_organizational_unit.security.id
    Workloads = aws_organizations_organizational_unit.workloads.id
    Prod      = aws_organizations_organizational_unit.prod.id
    NonProd   = aws_organizations_organizational_unit.nonprod.id
  }
}

output "platform_admin_group_id" {
  description = "Id of the IAM Identity Center group svp-platform-admins: platform_admin_group_id of aws/accounts/<env>."
  value       = aws_identitystore_group.platform["admins"].group_id
}

output "platform_viewer_group_id" {
  description = "Id of the IAM Identity Center group svp-platform-viewers: platform_viewer_group_id of aws/accounts/<env>."
  value       = aws_identitystore_group.platform["viewers"].group_id
}
