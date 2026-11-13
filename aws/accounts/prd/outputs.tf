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
  description = "The four name servers of the prd zone, aws.<domain>: the values of the four NS records aws at the DNS of the parent domain. The zone of prd delegates the stg zone (delegated_subdomains)."
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
  description = "URL of the Grafana workspace svp-<env>, where the platform groups sign in: key grafanaUrl of the cluster values."
  value       = module.observability.grafana_url
}

output "spans_retention_command" {
  description = "Command that sets the retention of the log group aws/spans, run once per account after the first session with spans."
  value       = module.observability.spans_retention_command
}
