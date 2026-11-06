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
