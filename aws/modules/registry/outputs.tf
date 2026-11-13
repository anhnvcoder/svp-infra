output "registry_host" {
  description = "Host of the private registry of the account, <account>.dkr.ecr.<region>.amazonaws.com: key ecrRegistry of the cluster values."
  value       = "${local.account_id}.dkr.ecr.${local.region}.${data.aws_partition.current.dns_suffix}"
}

output "release_repository_arns" {
  description = "ARN of each release repository, by repository name (svp-backend/gateway, svp-frontend/web)."
  value       = { for name, repo in aws_ecr_repository.release : name => repo.arn }
}

output "ci_role_arns" {
  description = "ARN of each role of ci_roles, by role name."
  value       = { for name, role in aws_iam_role.ci : name => role.arn }
}

output "cache_prefixes" {
  description = "Repository prefixes of the pull through cache rules (ghcr, docker-hub, quay, k8s, ecr-public): nodes import and create repositories under <prefix>/*."
  value       = keys(aws_ecr_pull_through_cache_rule.this)
}

output "kms_key_arn" {
  description = "ARN of the KMS key alias/svp-<env>-ecr that encrypts every repository of the registry."
  value       = aws_kms_key.ecr.arn
}
