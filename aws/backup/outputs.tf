output "kms_key_arn" {
  description = "ARN (key/<id>) of the key svp-backup-copy that encrypts both copy vaults."
  value       = aws_kms_key.copy.arn
}

output "vault_arns" {
  description = "ARN of each copy vault, by name (svp-stg-copy, svp-prd-copy): the targets of the copy actions of the backup policies, which name them by the backup account id."
  value       = module.vaults.vault_arns
}
