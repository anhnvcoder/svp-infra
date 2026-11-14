output "flags" {
  description = "Every account key (mgmt, log-archive, security, backup, stg, prd) to every flag (managed_grafana, inspector_ecr, security_hub, config_recording) and its value, always where aws/paid-features.json sets none."
  value       = local.by_account
}

output "off_accounts" {
  description = "Every flag to the sorted account keys where it is off; an empty list when no account turns it off."
  value       = { for f in keys(local.values) : f => sort([for a in local.accounts : a if local.by_account[a][f] == "off"]) }
}

output "session_accounts" {
  description = "Every flag to the sorted account keys where it is session (only managed_grafana takes it); an empty list when no account does."
  value       = { for f in keys(local.values) : f => sort([for a in local.accounts : a if local.by_account[a][f] == "session"]) }
}
