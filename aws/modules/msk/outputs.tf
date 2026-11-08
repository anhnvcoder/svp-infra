output "bootstrap_brokers" {
  description = "Bootstrap brokers for SASL/SCRAM over TLS, host:9096 of each broker separated by commas: key kafkaBrokers of the cluster values."
  value       = aws_msk_cluster.this.bootstrap_brokers_sasl_scram
}
