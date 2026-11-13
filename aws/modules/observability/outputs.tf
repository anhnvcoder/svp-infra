output "amp_workspace_id" {
  description = "Id of the Prometheus workspace `svp-<env>` (`ws-<uuid>`): ampWorkspaceId of the cluster values."
  value       = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  description = "ARN of the Prometheus workspace, for the Pod Identity roles that write, query or manage rules on it."
  value       = aws_prometheus_workspace.this.arn
}

output "amp_endpoint" {
  description = "Base URL of the Prometheus workspace, ending in /: ampEndpoint of the cluster values; api/v1/remote_write and api/v1/query are appended to it."
  value       = aws_prometheus_workspace.this.prometheus_endpoint

  # Two AWS pages disagree on the form of this URL; the cluster values accept only the base URL, so a different
  # form stops the apply here rather than in the cluster.
  precondition {
    condition     = can(regex("^https://aps-workspaces\\.[a-z]{2}(-[a-z]+)+-[0-9]+\\.amazonaws\\.com/workspaces/ws-[0-9a-f-]+/$", aws_prometheus_workspace.this.prometheus_endpoint))
    error_message = "The prometheus_endpoint of the workspace must be https://aps-workspaces.<region>.amazonaws.com/workspaces/<id>/, with the trailing slash."
  }
}

output "log_group_name" {
  description = "Name of the application log group `/svp/<env>/otel`: logGroup of the cluster values."
  value       = aws_cloudwatch_log_group.otel.name
}

output "log_group_arn" {
  description = "ARN of the application log group, without the :* suffix; its stream otel-collector is `<arn>:log-stream:otel-collector`."
  value       = aws_cloudwatch_log_group.otel.arn
}

output "grafana_url" {
  description = "URL of the Grafana workspace, https:// and its endpoint, no trailing slash: grafanaUrl of the cluster values."
  value       = "https://${aws_grafana_workspace.this.endpoint}"

  precondition {
    condition     = can(regex("^g-[0-9a-z]+\\.grafana-workspace\\.[a-z]{2}(-[a-z]+)+-[0-9]+\\.amazonaws\\.com$", aws_grafana_workspace.this.endpoint))
    error_message = "The endpoint of the Grafana workspace must be g-<id>.grafana-workspace.<region>.amazonaws.com."
  }
}

output "grafana_workspace_id" {
  description = "Id of the Grafana workspace (`g-<id>`), for the session script that makes the token of the service account svp-grafana-operator."
  value       = aws_grafana_workspace.this.id
}

output "kms_key_arn" {
  description = "ARN of the key `alias/svp-<env>-observability`, for the Collector's permission to write the encrypted log group."
  value       = aws_kms_key.observability.arn
}

output "spans_retention_command" {
  description = "Command the learner runs once per account, after X-Ray has created the log group aws/spans, to set its retention to span_retention_days: Terraform cannot create or adopt a log group whose name starts with aws/."
  value       = "AWS_PROFILE=anhnv-${var.env} aws logs put-retention-policy --log-group-name aws/spans --retention-in-days ${var.span_retention_days} --region ${local.region}"
}
