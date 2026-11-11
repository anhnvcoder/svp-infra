# CloudWatch alarms of the instance, outside the cluster so they still fire when the cluster is down. Thresholds follow
# the CloudWatch recommended alarms for RDS; the table, its sources and where it departs from them are in
# Design notes: aws/modules/rds/README.md.

locals {
  gib = 1024 * 1024 * 1024

  # Thresholds that follow the instance class: 25 % of its memory, 90 % of the default max_connections of its memory,
  # and its vCPU count for the database load.
  class_alarm_thresholds = {
    "db.t4g.small" = { freeable_memory_bytes = 0.5 * local.gib, connections = 186, db_load = 2 }
    "db.m7g.large" = { freeable_memory_bytes = 2 * local.gib, connections = 745, db_load = 2 }
  }
  class_thresholds = local.class_alarm_thresholds[var.instance_class]

  runbook_base_url = "https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks"

  # datapoints of evaluation_periods one-minute periods must breach. extended_statistic holds a percentile, statistic
  # every other aggregation.
  alarms = {
    rds-storage-low = {
      metric             = "FreeStorageSpace"
      statistic          = "Minimum"
      extended_statistic = null
      comparison         = "LessThanThreshold"
      threshold          = 0.1 * var.allocated_storage * local.gib
      datapoints         = 15
      evaluation_periods = 15
      severity           = "page"
      summary            = "Free storage of ${var.name} under 10 % of ${var.allocated_storage} GiB for 15 minutes: storage autoscaling did not grow it."
    }
    rds-txid-wraparound = {
      metric             = "MaximumUsedTransactionIDs"
      statistic          = "Average"
      extended_statistic = null
      comparison         = "GreaterThanThreshold"
      threshold          = 1000000000
      datapoints         = 1
      evaluation_periods = 1
      severity           = "page"
      summary            = "Over one billion transaction IDs of ${var.name} in use: vacuum must freeze before wraparound stops writes."
    }
    rds-cpu-high = {
      metric             = "CPUUtilization"
      statistic          = "Average"
      extended_statistic = null
      comparison         = "GreaterThanThreshold"
      threshold          = 90
      datapoints         = 5
      evaluation_periods = 5
      severity           = "ticket"
      summary            = "CPU of ${var.name} over 90 % for 5 minutes."
    }
    rds-memory-low = {
      metric             = "FreeableMemory"
      statistic          = "Average"
      extended_statistic = null
      comparison         = "LessThanThreshold"
      threshold          = local.class_thresholds.freeable_memory_bytes
      datapoints         = 15
      evaluation_periods = 15
      severity           = "ticket"
      summary            = "Freeable memory of ${var.name} under 25 % of the memory of ${var.instance_class} for 15 minutes."
    }
    rds-connections-high = {
      metric             = "DatabaseConnections"
      statistic          = "Average"
      extended_statistic = null
      comparison         = "GreaterThanThreshold"
      threshold          = local.class_thresholds.connections
      datapoints         = 5
      evaluation_periods = 5
      severity           = "ticket"
      summary            = "Connections to ${var.name} over 90 % of the default max_connections of ${var.instance_class} for 5 minutes."
    }
    rds-db-load-high = {
      metric             = "DBLoad"
      statistic          = "Average"
      extended_statistic = null
      comparison         = "GreaterThanThreshold"
      threshold          = local.class_thresholds.db_load
      datapoints         = 15
      evaluation_periods = 15
      severity           = "ticket"
      summary            = "Database load of ${var.name} over the vCPU count of ${var.instance_class} for 15 minutes."
    }
    rds-read-latency-high = {
      metric             = "ReadLatency"
      statistic          = null
      extended_statistic = "p90"
      comparison         = "GreaterThanThreshold"
      threshold          = 0.02
      datapoints         = 5
      evaluation_periods = 5
      severity           = "ticket"
      summary            = "p90 read latency of ${var.name} over 20 ms for 5 minutes."
    }
    rds-write-latency-high = {
      metric             = "WriteLatency"
      statistic          = null
      extended_statistic = "p90"
      comparison         = "GreaterThanThreshold"
      threshold          = 0.02
      datapoints         = 5
      evaluation_periods = 5
      severity           = "ticket"
      summary            = "p90 write latency of ${var.name} over 20 ms for 5 minutes."
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.severity == "page" ? "${each.value.summary} Runbook: ${local.runbook_base_url}/${each.key}.md" : each.value.summary
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = each.value.statistic
  extended_statistic  = each.value.extended_statistic
  period              = 60
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  datapoints_to_alarm = each.value.datapoints
  evaluation_periods  = each.value.evaluation_periods
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  tags = {
    Severity = each.value.severity
  }
}
