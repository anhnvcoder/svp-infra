output "vault_arns" {
  description = "ARN of each vault, by name: the target of a backup rule or of a copy action."
  value       = { for name, v in aws_backup_vault.this : name => v.arn }
}
