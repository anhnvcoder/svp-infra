# A message in the dead-letter queue is a video left in PROCESSING: the bridge never settled its job.
locals {
  runbook_base_url = "https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks"
  dlq_alarm        = "transcode-events-dlq"
}

resource "aws_cloudwatch_metric_alarm" "events_dlq" {
  alarm_name          = "${local.name}-${local.dlq_alarm}"
  alarm_description   = "Job state events of ${local.name} in the dead-letter queue: their videos stay in PROCESSING. Runbook: ${local.runbook_base_url}/${local.dlq_alarm}.md"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = local.events_dlq_name }
  statistic           = "Maximum"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  datapoints_to_alarm = 1
  evaluation_periods  = 1
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  tags = {
    Severity = "page"
  }
}
