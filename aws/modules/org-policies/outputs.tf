output "policy_ids" {
  description = "Id of each service control policy, by key (deny-leave-organization, protect-cloudtrail, deny-other-regions)."
  value       = { for k, p in aws_organizations_policy.this : k => p.id }
}
