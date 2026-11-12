output "state_bucket" {
  description = "Bucket of the remote state of the roots run with the management account's profile."
  value       = aws_s3_bucket.state.bucket
}

output "backend_hcl" {
  description = "Content of aws/backend.hcl, the partial backend configuration every root of the management account and github/ read with -backend-config: bucket, region, encryption with the KMS key of the state and the S3 lock file. It holds no key argument: each root sets the key of its own state."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    region       = "${var.region}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.state.arn}"
    use_lockfile = true
  EOT
}
