output "ebs_kms_key_arns" {
  description = "ARN (key/<id>) of the EBS key of each env account (stg, prd), the default key of new EBS volumes in the home region."
  value       = local.ebs_key_arns
}
