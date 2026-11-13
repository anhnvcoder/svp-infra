resource "aws_prometheus_workspace" "this" {
  alias       = local.name
  kms_key_arn = local.kms_key_arn
}

# rule_query_offset_in_seconds keeps the 60 s default of a new workspace: rules wait for late samples.
resource "aws_prometheus_workspace_configuration" "this" {
  workspace_id             = aws_prometheus_workspace.this.id
  retention_period_in_days = var.amp_retention_days
}
