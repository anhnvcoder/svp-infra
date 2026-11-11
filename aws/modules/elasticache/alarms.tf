# CloudWatch alarms of the replication group, outside the EKS cluster so they still fire when it is down. Thresholds
# follow the CloudWatch recommended alarms for ElastiCache; the table and its sources are in the design notes.
# Design notes: aws/modules/elasticache/README.md.

locals {
  runbook_base_url = "https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks"

  # With cluster mode off every node is a cache cluster of its own, named <replication group id>-001, -002 and so on;
  # the names follow from node_count so the plan knows them. An alarm takes the highest node at each minute (MAX).
  node_ids = [for i in range(1, var.node_count + 1) : format("%s-%03d", var.name, i)]

  # datapoints of evaluation_periods one-minute periods must breach.
  alarms = {
    valkey-memory-high = {
      metric             = "DatabaseMemoryUsagePercentage"
      statistic          = "Average"
      threshold          = 80
      datapoints         = 5
      evaluation_periods = 5
      severity           = "page"
      summary            = "Memory of a node of ${var.name} over 80 % for 5 minutes: with noeviction a full memory fails every write."
    }
    valkey-engine-cpu-high = {
      metric             = "EngineCPUUtilization"
      statistic          = "Average"
      threshold          = 90
      datapoints         = 5
      evaluation_periods = 5
      severity           = "ticket"
      summary            = "CPU of the Valkey engine thread of a node of ${var.name} over 90 % for 5 minutes."
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.severity == "page" ? "${each.value.summary} Runbook: ${local.runbook_base_url}/${each.key}.md" : each.value.summary
  comparison_operator = "GreaterThanThreshold"
  threshold           = each.value.threshold
  datapoints_to_alarm = each.value.datapoints
  evaluation_periods  = each.value.evaluation_periods
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  metric_query {
    id          = "e1"
    expression  = "MAX([${join(", ", [for i, _ in local.node_ids : "m${i}"])}])"
    label       = each.key
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.node_ids

    content {
      id = "m${metric_query.key}"

      metric {
        namespace   = "AWS/ElastiCache"
        metric_name = each.value.metric
        dimensions  = { CacheClusterId = metric_query.value }
        stat        = each.value.statistic
        period      = 60
      }
    }
  }

  tags = {
    Severity = each.value.severity
  }
}
