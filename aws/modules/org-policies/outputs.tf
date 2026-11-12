output "policy_ids" {
  description = "Id of each policy of the organization, by key (deny-leave-organization, protect-cloudtrail, deny-other-regions, protect-baseline, deny-iam-users, prod-guardrails, data-perimeter, ec2-baseline, tags)."
  value       = { for k, p in aws_organizations_policy.this : k => p.id }
}
