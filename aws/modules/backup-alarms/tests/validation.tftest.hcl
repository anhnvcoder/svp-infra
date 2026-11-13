# The two backup alarms: names, the Metrics Insights query over the AWS/Backup namespace, threshold, severity, no data
# as not breaching and the topic; then one plan per validation rule with a value that only that rule rejects. The AWS
# provider is a mock.

mock_provider "aws" {}

variables {
  name            = "svp-stg"
  alarm_topic_arn = "arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"
}

run "valid" {
  command = plan

  assert {
    condition     = toset([for a in aws_cloudwatch_metric_alarm.this : a.alarm_name]) == toset(["svp-stg-backup-job-failed", "svp-stg-backup-copy-failed"])
    error_message = "The module must make exactly the alarms <name>-backup-job-failed and <name>-backup-copy-failed."
  }

  assert {
    condition = alltrue([for key, metric in { backup-job-failed = "NumberOfBackupJobsFailed", backup-copy-failed = "NumberOfCopyJobsFailed" } :
      length(aws_cloudwatch_metric_alarm.this[key].metric_query) == 1 &&
      alltrue([for q in aws_cloudwatch_metric_alarm.this[key].metric_query :
        q.expression == "SELECT SUM(${metric}) FROM \"AWS/Backup\"" && q.period == 300 && q.return_data == true && length(q.metric) == 0
      ])
    ])
    error_message = "Each alarm must sum its failed-job metric over the whole AWS/Backup namespace every 5 minutes."
  }

  assert {
    condition = alltrue([for a in aws_cloudwatch_metric_alarm.this :
      a.comparison_operator == "GreaterThanThreshold" && a.threshold == 0 && a.evaluation_periods == 1 && a.datapoints_to_alarm == 1 &&
      a.metric_name == null && a.namespace == null
    ])
    error_message = "Each alarm must fire on the first 5-minute period with one failed job or more."
  }

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.this : a.treat_missing_data == "notBreaching"])
    error_message = "No data (no failed job published) must not breach."
  }

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.this : a.tags == tomap({ Severity = "ticket" })])
    error_message = "Each alarm must carry the tag Severity=ticket, and no other tag of its own."
  }

  assert {
    condition = alltrue([for a in aws_cloudwatch_metric_alarm.this :
      a.alarm_actions == toset(["arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"]) &&
      a.ok_actions == toset(["arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"])
    ])
    error_message = "Each alarm must notify alarm_topic_arn when it fires and when it clears."
  }
}

run "name_double_hyphen" {
  command = plan

  variables {
    name = "svp--stg"
  }

  expect_failures = [var.name]
}

run "alarm_topic_arn_not_sns" {
  command = plan

  variables {
    alarm_topic_arn = "arn:aws:sqs:ap-southeast-1:000000000000:svp-stg-alarms"
  }

  expect_failures = [var.alarm_topic_arn]
}
