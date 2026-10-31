output "address" {
  description = "Host name of the instance (resolves to its private address inside the VPC)."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port of the instance."
  value       = aws_db_instance.this.port
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret in which RDS keeps the master password (JSON with username and password). Not a secret itself; reading the value takes secretsmanager:GetSecretValue."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Security group of the instance; network policies and egress rules of the cluster point at it."
  value       = aws_security_group.this.id
}
