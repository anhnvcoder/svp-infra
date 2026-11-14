# MediaConvert of an env: an on-demand queue, the role jobs run with, and the way job states come back to the bridge
# (an EventBridge rule into an SQS queue with a dead-letter queue). Design notes: aws/modules/transcode/README.md.

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  name = "svp-${var.env}"

  # ARNs are built from their parts rather than read from the resources, so every policy and the event pattern are
  # known at plan time.
  arn_prefix     = "arn:${data.aws_partition.current.partition}"
  account_id     = data.aws_caller_identity.current.account_id
  account_region = "${data.aws_region.current.region}:${local.account_id}"

  queue_arn       = "${local.arn_prefix}:mediaconvert:${local.account_region}:queues/${local.name}"
  jobs_arn        = "${local.arn_prefix}:mediaconvert:${local.account_region}:jobs/*"
  role_name       = "${local.name}-mediaconvert"
  role_arn        = "${local.arn_prefix}:iam::${local.account_id}:role/${local.role_name}"
  rule_name       = "${local.name}-mediaconvert-job-state"
  rule_arn        = "${local.arn_prefix}:events:${local.account_region}:rule/${local.rule_name}"
  events_name     = "${local.name}-transcode-events"
  events_arn      = "${local.arn_prefix}:sqs:${local.account_region}:${local.events_name}"
  events_dlq_name = "${local.events_name}-dlq"
  events_dlq_arn  = "${local.arn_prefix}:sqs:${local.account_region}:${local.events_dlq_name}"
}

# On demand: billed per output minute only, nothing while no job runs.
resource "aws_media_convert_queue" "this" {
  name         = local.name
  description  = "Transcode jobs of ${local.name}"
  pricing_plan = "ON_DEMAND"
  status       = "ACTIVE"
}
