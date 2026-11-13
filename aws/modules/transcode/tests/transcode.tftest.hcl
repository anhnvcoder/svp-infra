# What the transcode module of an env guarantees, for stg and prd, then one plan per validation rule with a value that
# only that rule rejects. The AWS provider is a mock: nothing reaches an account. Policies are asserted through the
# arguments of their aws_iam_policy_document data sources, each statement as one JSON string, so a policy must equal
# its table exactly: no statement, action, resource or condition more or less. Design notes: README.md of the module.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }
}

variables {
  env                = "stg"
  uploads_bucket_arn = "arn:aws:s3:::svp-stg-uploads-000000000000-ap-southeast-1"
  media_bucket_arn   = "arn:aws:s3:::svp-stg-media-000000000000-ap-southeast-1"
  alarm_topic_arn    = "arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"

  uploads_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/0123abcd-4567-89ef-0123-456789abcdef"

  # ARNs of the stg resources, as AWS writes them.
  queue_arn      = "arn:aws:mediaconvert:ap-southeast-1:000000000000:queues/svp-stg"
  role_arn       = "arn:aws:iam::000000000000:role/svp-stg-mediaconvert"
  rule_arn       = "arn:aws:events:ap-southeast-1:000000000000:rule/svp-stg-mediaconvert-job-state"
  events_arn     = "arn:aws:sqs:ap-southeast-1:000000000000:svp-stg-transcode-events"
  events_dlq_arn = "arn:aws:sqs:ap-southeast-1:000000000000:svp-stg-transcode-events-dlq"
}

run "stg" {
  command = plan

  assert {
    condition = (
      aws_media_convert_queue.this.name == "svp-stg" && aws_media_convert_queue.this.pricing_plan == "ON_DEMAND" &&
      aws_media_convert_queue.this.status == "ACTIVE"
    )
    error_message = "The MediaConvert queue must be svp-stg, on demand and active."
  }

  # Role MediaConvert: trusted by MediaConvert for the jobs of this account and this queue only.
  assert {
    condition = aws_iam_role.mediaconvert.name == "svp-stg-mediaconvert" && toset([
      for s in data.aws_iam_policy_document.mediaconvert_trust.statement : jsonencode([
        s.effect, sort(s.actions), [for p in s.principals : [p.type, sort(p.identifiers)]],
        sort([for c in s.condition : jsonencode([c.test, c.variable, c.values])]),
      ])
      ]) == toset([jsonencode([
        "Allow", ["sts:AssumeRole"], [["Service", ["mediaconvert.amazonaws.com"]]],
        sort([
          jsonencode(["StringEquals", "aws:SourceAccount", ["000000000000"]]),
          jsonencode(["ArnLike", "aws:SourceArn", [var.queue_arn]]),
        ]),
    ])])
    error_message = "The role svp-stg-mediaconvert must trust mediaconvert.amazonaws.com only, with aws:SourceAccount and aws:SourceArn of the queue."
  }

  # Exactly the table "Role MediaConvert" of the design: read uploads/* and decrypt it with the uploads key, write
  # media/*, nothing else.
  assert {
    condition = toset([
      for s in data.aws_iam_policy_document.mediaconvert.statement : jsonencode([
        s.effect, sort(s.actions), sort(s.resources), length(s.principals), length(s.condition), s.not_actions, s.not_resources,
      ])
      ]) == toset([
      jsonencode(["Allow", ["s3:GetObject"], ["${var.uploads_bucket_arn}/uploads/*"], 0, 0, null, null]),
      jsonencode(["Allow", ["kms:Decrypt"], [var.uploads_kms_key_arn], 0, 0, null, null]),
      jsonencode(["Allow", ["s3:PutObject"], ["${var.media_bucket_arn}/media/*"], 0, 0, null, null]),
    ]) && aws_iam_role_policy.mediaconvert.policy == data.aws_iam_policy_document.mediaconvert.json
    error_message = "The policy of the MediaConvert role must be exactly s3:GetObject on uploads/*, kms:Decrypt on the uploads key and s3:PutObject on media/*."
  }

  # Exactly the MediaConvert, iam:PassRole and SQS rows of the table "bridge permissions" of the design.
  assert {
    condition = toset([
      for s in data.aws_iam_policy_document.bridge.statement : jsonencode([
        s.effect, sort(s.actions), sort(s.resources), length(s.principals),
        sort([for c in s.condition : jsonencode([c.test, c.variable, c.values])]), s.not_actions, s.not_resources,
      ])
      ]) == toset([
      jsonencode(["Allow", ["mediaconvert:CreateJob"], [var.queue_arn], 0, [], null, null]),
      jsonencode(["Allow", ["mediaconvert:GetJob"], ["arn:aws:mediaconvert:ap-southeast-1:000000000000:jobs/*"], 0, [], null, null]),
      jsonencode(["Allow", ["mediaconvert:Probe"], ["*"], 0, [], null, null]),
      jsonencode(["Allow", ["iam:PassRole"], [var.role_arn], 0,
        [jsonencode(["StringEquals", "iam:PassedToService", ["mediaconvert.amazonaws.com"]])], null, null
      ]),
      jsonencode(["Allow", ["sqs:ChangeMessageVisibility", "sqs:DeleteMessage", "sqs:ReceiveMessage"], [var.events_arn], 0, [], null, null]),
    ])
    error_message = "The bridge policy must be exactly CreateJob on the queue, GetJob on jobs/*, Probe, PassRole of the MediaConvert role to mediaconvert.amazonaws.com, and the three SQS actions on the events queue."
  }

  # Job state event: final states of this env's queue only, into the events queue, undeliverable ones to the DLQ.
  assert {
    condition = aws_cloudwatch_event_rule.job_state.name == "svp-stg-mediaconvert-job-state" && jsondecode(aws_cloudwatch_event_rule.job_state.event_pattern) == {
      source        = ["aws.mediaconvert"]
      "detail-type" = ["MediaConvert Job State Change"]
      detail        = { status = ["COMPLETE", "ERROR"], queue = [var.queue_arn] }
    }
    error_message = "The rule svp-stg-mediaconvert-job-state must match COMPLETE and ERROR of MediaConvert jobs of queue svp-stg, nothing else."
  }

  assert {
    condition = (
      aws_cloudwatch_event_target.job_state.rule == "svp-stg-mediaconvert-job-state" &&
      aws_cloudwatch_event_target.job_state.arn == var.events_arn &&
      one(aws_cloudwatch_event_target.job_state.dead_letter_config).arn == var.events_dlq_arn
    )
    error_message = "The rule must send to svp-stg-transcode-events, with svp-stg-transcode-events-dlq as dead-letter queue."
  }

  # Queue of the job state events: SSE-SQS, redrive to the DLQ after 5 receives.
  assert {
    condition = (
      aws_sqs_queue.events.name == "svp-stg-transcode-events" && aws_sqs_queue.events.sqs_managed_sse_enabled &&
      jsondecode(aws_sqs_queue.events.redrive_policy) == { deadLetterTargetArn = var.events_dlq_arn, maxReceiveCount = 5 }
    )
    error_message = "svp-stg-transcode-events must use SSE-SQS that redrives to svp-stg-transcode-events-dlq after 5 receives."
  }

  assert {
    condition = (
      aws_sqs_queue.events_dlq.name == "svp-stg-transcode-events-dlq" && aws_sqs_queue.events_dlq.sqs_managed_sse_enabled &&
      aws_sqs_queue.events_dlq.message_retention_seconds == 1209600
    )
    error_message = "svp-stg-transcode-events-dlq must use SSE-SQS and keep messages 14 days."
  }

  # Each queue policy: only the rule may send (events.amazonaws.com with aws:SourceArn), and no request without TLS.
  assert {
    condition = alltrue([for q, st in {
      (var.events_arn)     = data.aws_iam_policy_document.queue["events"].statement
      (var.events_dlq_arn) = data.aws_iam_policy_document.queue["events_dlq"].statement
      } : toset([for s in st : jsonencode([
        s.effect, sort(s.actions), sort(s.resources), [for p in s.principals : [p.type, sort(p.identifiers)]],
        sort([for c in s.condition : jsonencode([c.test, c.variable, c.values])]),
        ])]) == toset([
        jsonencode(["Allow", ["sqs:SendMessage"], [q], [["Service", ["events.amazonaws.com"]]],
        [jsonencode(["ArnEquals", "aws:SourceArn", [var.rule_arn]])]]),
        jsonencode(["Deny", ["sqs:*"], [q], [["*", ["*"]]], [jsonencode(["Bool", "aws:SecureTransport", ["false"]])]]),
    ])])
    error_message = "The policy of each queue must allow only sqs:SendMessage from events.amazonaws.com for the rule, and deny every request without TLS."
  }

  assert {
    condition = (
      aws_sqs_queue_policy.events.policy == data.aws_iam_policy_document.queue["events"].json &&
      aws_sqs_queue_policy.events_dlq.policy == data.aws_iam_policy_document.queue["events_dlq"].json
    )
    error_message = "Each queue must carry its own policy document."
  }

  # Alarm: a message in the DLQ pages, with the runbook of the same name.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.events_dlq.alarm_name == "svp-stg-transcode-events-dlq" &&
      aws_cloudwatch_metric_alarm.events_dlq.namespace == "AWS/SQS" &&
      aws_cloudwatch_metric_alarm.events_dlq.metric_name == "ApproximateNumberOfMessagesVisible" &&
      aws_cloudwatch_metric_alarm.events_dlq.dimensions == tomap({ QueueName = "svp-stg-transcode-events-dlq" }) &&
      aws_cloudwatch_metric_alarm.events_dlq.comparison_operator == "GreaterThanThreshold" &&
      aws_cloudwatch_metric_alarm.events_dlq.threshold == 0 &&
      aws_cloudwatch_metric_alarm.events_dlq.tags == tomap({ Severity = "page" }) &&
      aws_cloudwatch_metric_alarm.events_dlq.alarm_actions == toset([var.alarm_topic_arn]) &&
      aws_cloudwatch_metric_alarm.events_dlq.ok_actions == toset([var.alarm_topic_arn]) &&
      endswith(aws_cloudwatch_metric_alarm.events_dlq.alarm_description,
      "Runbook: https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/transcode-events-dlq.md")
    )
    error_message = "The alarm svp-stg-transcode-events-dlq must page the alarm topic as soon as the DLQ holds a message, with the runbook transcode-events-dlq."
  }
}

run "prd" {
  command = plan

  variables {
    env                 = "prd"
    uploads_bucket_arn  = "arn:aws:s3:::svp-prd-uploads-000000000000-ap-southeast-1"
    media_bucket_arn    = "arn:aws:s3:::svp-prd-media-000000000000-ap-southeast-1"
    alarm_topic_arn     = "arn:aws:sns:ap-southeast-1:000000000000:svp-prd-alarms"
    uploads_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/89abcdef-0123-4567-89ab-cdef01234567"
  }

  assert {
    condition = (
      aws_media_convert_queue.this.name == "svp-prd" && aws_iam_role.mediaconvert.name == "svp-prd-mediaconvert" &&
      aws_cloudwatch_event_rule.job_state.name == "svp-prd-mediaconvert-job-state" &&
      aws_sqs_queue.events.name == "svp-prd-transcode-events" && aws_sqs_queue.events_dlq.name == "svp-prd-transcode-events-dlq" &&
      aws_cloudwatch_metric_alarm.events_dlq.alarm_name == "svp-prd-transcode-events-dlq"
    )
    error_message = "Every name of prd must start with svp-prd."
  }

  assert {
    condition = (
      jsondecode(aws_cloudwatch_event_rule.job_state.event_pattern).detail.queue == ["arn:aws:mediaconvert:ap-southeast-1:000000000000:queues/svp-prd"] &&
      contains(flatten([for s in data.aws_iam_policy_document.mediaconvert_trust.statement : [for c in s.condition : c.values]]),
      "arn:aws:mediaconvert:ap-southeast-1:000000000000:queues/svp-prd") &&
      contains(flatten([for s in data.aws_iam_policy_document.bridge.statement : s.resources]), "arn:aws:iam::000000000000:role/svp-prd-mediaconvert")
    )
    error_message = "The rule, the trust and the bridge policy of prd must name the queue and role of prd."
  }

  assert {
    condition = toset(flatten([for s in data.aws_iam_policy_document.mediaconvert.statement : s.resources])) == toset([
      "arn:aws:s3:::svp-prd-uploads-000000000000-ap-southeast-1/uploads/*", "arn:aws:s3:::svp-prd-media-000000000000-ap-southeast-1/media/*",
      "arn:aws:kms:ap-southeast-1:000000000000:key/89abcdef-0123-4567-89ab-cdef01234567",
    ])
    error_message = "The MediaConvert role of prd must reach the buckets and the uploads key of prd only."
  }
}

run "env_rejected" {
  command = plan

  variables {
    env = "svp-stg"
  }

  expect_failures = [var.env]
}

run "uploads_bucket_arn_empty_rejected" {
  command = plan

  variables {
    uploads_bucket_arn = ""
  }

  expect_failures = [var.uploads_bucket_arn]
}

run "media_bucket_arn_empty_rejected" {
  command = plan

  variables {
    media_bucket_arn = ""
  }

  expect_failures = [var.media_bucket_arn]
}

run "uploads_kms_key_arn_wildcard_rejected" {
  command = plan

  variables {
    uploads_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/*"
  }

  expect_failures = [var.uploads_kms_key_arn]
}

run "uploads_kms_key_arn_account_rejected" {
  command = plan

  variables {
    uploads_kms_key_arn = "arn:aws:kms:ap-southeast-1:00000000000:key/0123abcd-4567-89ef-0123-456789abcdef"
  }

  expect_failures = [var.uploads_kms_key_arn]
}

run "alarm_topic_arn_rejected" {
  command = plan

  variables {
    alarm_topic_arn = "svp-stg-alarms"
  }

  expect_failures = [var.alarm_topic_arn]
}
