output "state_bucket" {
  description = "Bucket of the remote state of aws/bootstrap, aws/org and github/."
  value       = aws_s3_bucket.state.bucket
}

output "backend_hcl" {
  description = "Content of aws/backend.hcl, the partial backend configuration aws/bootstrap, aws/org and github/ read with -backend-config."
  value       = "bucket = \"${aws_s3_bucket.state.bucket}\"\nregion = \"${var.region}\"\n"
}
