output "bucket_names" {
  description = "Name of each log bucket, by kind (cloudtrail, cloudtrail_access, config, flowlogs, guardduty, waf). Other roots derive the same names from the account id; this output is for checking."
  value       = { for k, b in aws_s3_bucket.log : k => b.bucket }
}

output "bucket_arns" {
  description = "ARN of each log bucket, by kind."
  value       = { for k, b in aws_s3_bucket.log : k => b.arn }
}

output "kms_key_arns" {
  description = "ARN (key/<id>) of each log archive key: home (home region: trail, Config, flow logs, GuardDuty) and waf (us-east-1: WAF logs). Other roots read the home one with the data source aws_kms_alias."
  value       = { for k, key in aws_kms_key.log : k => key.arn }
}

output "kms_alias_name" {
  description = "Alias of both log archive keys, one per region."
  value       = one(distinct([for a in aws_kms_alias.log : a.name]))
}
