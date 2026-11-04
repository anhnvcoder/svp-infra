output "roles" {
  description = "ARN of the IAM role of each namespace's SecretStore, by namespace: key externalSecretsRoles of the cluster values."
  value       = { for ns, role in aws_iam_role.namespace : ns => role.arn }
}

output "secret_arns" {
  description = "ARN of each Secrets Manager entry, by entry name (the secret is svp/<env>/<entry>)."
  value       = { for e, secret in aws_secretsmanager_secret.this : e => secret.arn }
}
