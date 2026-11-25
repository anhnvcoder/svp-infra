output "ebs_kms_key_arns" {
  description = "ARN (key/<id>) of the former EBS key of each env account (stg, prd), kept while a volume or snapshot may still use it."
  value       = { stg = aws_kms_key.stg_ebs.arn, prd = aws_kms_key.prd_ebs.arn }
}
