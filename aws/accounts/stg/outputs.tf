output "state_bucket" {
  description = "Bucket of the remote state of every root of this account."
  value       = module.baseline.state_bucket
}

output "backend_hcl" {
  description = "Content of aws/backend-<env>.hcl, read with -backend-config by every root of this account."
  value       = module.baseline.backend_hcl
}

output "zone_id" {
  description = "Id of the hosted zone of the environment (hosted_zone_id of the environment root)."
  value       = module.baseline.zone_id
}

output "name_servers" {
  description = "The four name servers of the stg zone: the value of its entry in delegated_subdomains of aws/accounts/prd."
  value       = module.baseline.name_servers
}

output "registry_host" {
  description = "Host of the private ECR registry of the account: key ecrRegistry of the cluster values, and the registry CI copies releases into."
  value       = module.registry.registry_host
}

output "ci_role_arns" {
  description = "ARN of each role GitHub Actions assumes to copy releases into the registry, by role name."
  value       = module.registry.ci_role_arns
}

output "amp_workspace_id" {
  description = "Id of the Prometheus workspace svp-<env> (ws-<uuid>): key ampWorkspaceId of the cluster values."
  value       = module.observability.amp_workspace_id
}

output "grafana_url" {
  description = "URL of the Grafana workspace svp-<env>, where the platform groups sign in: key grafanaUrl of the cluster values. Null while the workspace does not exist (managed_grafana at session and no session open)."
  value       = module.observability.grafana_url
}

output "session_features" {
  description = "The cost flags of aws/paid-features.json whose value for this env is session: what the account commands of aws/scripts/tf.sh open and close with each session. Empty when every resource of this root lives between sessions."
  value       = [for f, accounts in module.paid_features.session_accounts : f if contains(accounts, local.env)]
}

output "spans_retention_command" {
  description = "Command that sets the retention of the log group aws/spans, run once per account after the first session with spans."
  value       = module.observability.spans_retention_command
}

output "backup_vault_arn" {
  description = "ARN of the AWS Backup vault svp-<env>, where the backup policy of the organization and the on-demand jobs of a session write recovery points."
  value       = module.backup_vault.vault_arns["svp-${local.env}"]
}

output "backup_key_arn" {
  description = "ARN of the KMS key alias/svp-<env>-backup that encrypts the vault svp-<env>."
  value       = aws_kms_key.backup.arn
}

output "backup_role_arn" {
  description = "ARN of the role svp-<env>-backup that AWS Backup assumes for the backup, copy and restore jobs of the account."
  value       = aws_iam_role.backup.arn
}
