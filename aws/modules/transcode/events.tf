# Job states come back through an SQS queue rather than to a subscriber, so the bridge gets them even when it was down.
# A message the bridge cannot act on is received again until maxReceiveCount, then redriven to the dead-letter queue,
# which also catches events EventBridge could not deliver.
locals {
  max_receive_count = 5
}

resource "aws_sqs_queue" "events_dlq" {
  name                    = local.events_dlq_name
  sqs_managed_sse_enabled = true

  # The longest SQS allows: an operator moves messages back only after fixing the cause.
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "events" {
  name                    = local.events_name
  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = local.events_dlq_arn
    maxReceiveCount     = local.max_receive_count
  })

  # SQS refuses a redrive policy whose dead-letter queue does not exist yet.
  depends_on = [aws_sqs_queue.events_dlq]
}

# Only the rule below may send, to either queue; nothing reaches them over plain HTTP. The Deny names sqs:* so that an
# action SQS adds later is refused over HTTP too; a Deny grants nothing.
data "aws_iam_policy_document" "queue" {
  for_each = {
    events     = local.events_arn
    events_dlq = local.events_dlq_arn
  }

  statement {
    sid       = "JobStateRule"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [each.value]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.rule_arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "events_dlq" {
  queue_url = aws_sqs_queue.events_dlq.id
  policy    = data.aws_iam_policy_document.queue["events_dlq"].json
}

resource "aws_sqs_queue_policy" "events" {
  queue_url = aws_sqs_queue.events.id
  policy    = data.aws_iam_policy_document.queue["events"].json
}

# Final states of the jobs of this env's queue only; SUBMITTED and PROGRESSING decide nothing.
resource "aws_cloudwatch_event_rule" "job_state" {
  name        = local.rule_name
  description = "COMPLETE and ERROR of the jobs of MediaConvert queue ${local.name}"
  event_pattern = jsonencode({
    source        = ["aws.mediaconvert"]
    "detail-type" = ["MediaConvert Job State Change"]
    detail = {
      status = ["COMPLETE", "ERROR"]
      queue  = [local.queue_arn]
    }
  })
}

resource "aws_cloudwatch_event_target" "job_state" {
  rule      = aws_cloudwatch_event_rule.job_state.name
  target_id = local.events_name
  arn       = local.events_arn

  # Without it EventBridge drops an event it could not deliver once its retries run out.
  dead_letter_config {
    arn = local.events_dlq_arn
  }

  # Both queues must accept the rule before the first event arrives.
  depends_on = [aws_sqs_queue_policy.events, aws_sqs_queue_policy.events_dlq]
}
