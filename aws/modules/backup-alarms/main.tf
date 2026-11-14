# CloudWatch alarms on failed backup and copy jobs of the account. AWS Backup documents only example dimensions for its
# metrics, so each alarm is a Metrics Insights query over the whole namespace instead of one metric per dimension set.
# Design notes: aws/modules/backup-alarms/README.md.

locals {
  # AWS Backup publishes its metrics every 5 minutes. The vault of a copy job's metrics is the destination vault.
  alarms = {
    backup-job-failed = {
      metric  = "NumberOfBackupJobsFailed"
      summary = "A backup job of ${var.name} failed in the last 5 minutes."
    }
    backup-copy-failed = {
      metric  = "NumberOfCopyJobsFailed"
      summary = "A copy job of ${var.name} to another account or region failed in the last 5 minutes."
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.summary
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  datapoints_to_alarm = 1
  evaluation_periods  = 1
  # A period without data points (no job ran) is a period without failed jobs.
  treat_missing_data = "notBreaching"
  alarm_actions      = [var.alarm_topic_arn]
  ok_actions         = [var.alarm_topic_arn]

  metric_query {
    id          = "q1"
    expression  = "SELECT SUM(${each.value.metric}) FROM \"AWS/Backup\""
    period      = 300
    label       = each.key
    return_data = true
  }

  tags = {
    Severity = "ticket"
  }
}
