# No kms_key_arn: AMP encrypts with an AWS owned key. A customer managed key binds the workspace to it for good and
# makes every writer, reader and rule manager need KMS permissions, without keeping anyone in the account from the data.
resource "aws_prometheus_workspace" "this" {
  alias = local.name
}

# rule_query_offset_in_seconds keeps the 60 s default of a new workspace: rules wait for late samples.
resource "aws_prometheus_workspace_configuration" "this" {
  workspace_id             = aws_prometheus_workspace.this.id
  retention_period_in_days = var.amp_retention_days
}
