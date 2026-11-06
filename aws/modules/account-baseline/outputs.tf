output "state_bucket" {
  description = "Bucket of the remote state of every root of this account."
  value       = aws_s3_bucket.state.bucket
}

output "backend_hcl" {
  description = "Content of aws/backend-<env>.hcl, the partial backend configuration every root of this account reads with -backend-config: bucket, region, encryption with the KMS key of the state and the S3 lock file. It holds no key argument: each root sets the key of its own state."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    region       = "${var.region}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.state.arn}"
    use_lockfile = true
  EOT
}

output "zone_id" {
  description = "Id of the hosted zone of the environment, zone_name."
  value       = aws_route53_zone.env.zone_id
}

output "name_servers" {
  description = "The four name servers of the environment's zone, which the zone above it delegates with NS records: the zone of prd for stg (delegated_subdomains of aws/accounts/prd), the NS records aws at the parent domain's DNS for prd."
  value       = aws_route53_zone.env.name_servers
}
