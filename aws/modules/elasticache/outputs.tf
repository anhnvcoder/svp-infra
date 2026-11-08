output "primary_endpoint_address" {
  description = "Host name of the primary node, without port (clients connect on 6379 over TLS): key valkeyHost of the cluster values."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}
