# Standard class (not Infrequent Access) for Live Tail during a session; the class cannot change once created. No
# kms_key_id: CloudWatch Logs encrypts with its own key, and every reader of the group is a role of the account.
resource "aws_cloudwatch_log_group" "otel" {
  name              = local.log_group_name
  log_group_class   = "STANDARD"
  retention_in_days = var.log_retention_days
}

# The OTLP endpoint of CloudWatch Logs writes only to an existing stream.
resource "aws_cloudwatch_log_stream" "otel_collector" {
  name           = "otel-collector"
  log_group_name = aws_cloudwatch_log_group.otel.name
}
