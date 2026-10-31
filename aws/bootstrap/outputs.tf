output "state_bucket" {
  description = "Bucket of the remote state of every root."
  value       = aws_s3_bucket.state.bucket
}

output "backend_hcl" {
  description = "Content of aws/backend.hcl, the partial backend configuration every root reads with -backend-config."
  value       = "bucket = \"${aws_s3_bucket.state.bucket}\"\nregion = \"${var.region}\"\n"
}

output "zone_id" {
  description = "Id of the hosted zone of the lab subdomain."
  value       = aws_route53_zone.lab.zone_id
}

output "name_servers" {
  description = "The four name servers to delegate the lab subdomain to, as NS records at the DNS of the parent domain."
  value       = aws_route53_zone.lab.name_servers
}
