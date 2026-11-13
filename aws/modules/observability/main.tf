data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# Design notes: aws/modules/observability/README.md.
locals {
  name       = "svp-${var.env}"
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  log_group_name = "/svp/${var.env}/otel"
  log_group_arn  = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}"

  # Built from known parts around the generated id rather than taken from the resources' arn, so plans (and the mocked
  # tests) see which key and which workspace each setting and policy names.
  kms_key_arn       = "arn:${local.partition}:kms:${local.region}:${local.account_id}:key/${aws_kms_key.observability.key_id}"
  amp_workspace_arn = "arn:${local.partition}:aps:${local.region}:${local.account_id}:workspace/${aws_prometheus_workspace.this.id}"
}
