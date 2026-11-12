# CloudWatch alarms of the cluster, outside the EKS cluster so they still fire when it is down. Levels follow the MSK
# best practices; the table and its sources are in the design notes.
# Design notes: aws/modules/msk/README.md.

locals {
  runbook_base_url = "https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks"

  # MSK numbers its brokers from 1. A per-broker alarm takes the highest broker at each minute (metric math MAX), so
  # there is one alarm per kind whatever the broker count.
  broker_ids = range(1, var.broker_count + 1)

  # metrics are added up per broker before the MAX (CPU is user plus system). per_broker false reads the cluster-level
  # metric. datapoints of evaluation_periods one-minute periods must breach.
  alarms = {
    msk-disk-high = {
      metrics            = ["KafkaDataLogsDiskUsed"]
      per_broker         = true
      statistic          = "Maximum"
      comparison         = "GreaterThanOrEqualToThreshold"
      threshold          = 85
      datapoints         = 5
      evaluation_periods = 5
      severity           = "page"
      summary            = "Data log disk of a broker of ${var.name} at 85 % or more for 5 minutes: storage autoscaling did not grow it."
    }
    msk-offline-partitions = {
      metrics            = ["OfflinePartitionsCount"]
      per_broker         = false
      statistic          = "Maximum"
      comparison         = "GreaterThanThreshold"
      threshold          = 0
      datapoints         = 1
      evaluation_periods = 1
      severity           = "page"
      summary            = "Partitions of ${var.name} without a leader: they accept no read or write."
    }
    msk-under-min-isr = {
      metrics            = ["UnderMinIsrPartitionCount"]
      per_broker         = true
      statistic          = "Maximum"
      comparison         = "GreaterThanThreshold"
      threshold          = 0
      datapoints         = 5
      evaluation_periods = 5
      severity           = "page"
      summary            = "Partitions of ${var.name} under min.insync.replicas for 5 minutes: producers with acks=all fail."
    }
    msk-under-replicated = {
      metrics            = ["UnderReplicatedPartitions"]
      per_broker         = true
      statistic          = "Maximum"
      comparison         = "GreaterThanThreshold"
      threshold          = 0
      datapoints         = 15
      evaluation_periods = 15
      severity           = "ticket"
      summary            = "Under-replicated partitions on a broker of ${var.name} for 15 minutes."
    }
    msk-cpu-high = {
      metrics            = ["CpuUser", "CpuSystem"]
      per_broker         = true
      statistic          = "Average"
      comparison         = "GreaterThanThreshold"
      threshold          = 60
      datapoints         = 15
      evaluation_periods = 15
      severity           = "ticket"
      summary            = "CPU (user plus system) of a broker of ${var.name} over 60 % for 15 minutes."
    }
    msk-heap-high = {
      metrics            = ["HeapMemoryAfterGC"]
      per_broker         = true
      statistic          = "Average"
      comparison         = "GreaterThanThreshold"
      threshold          = 60
      datapoints         = 5
      evaluation_periods = 5
      severity           = "ticket"
      summary            = "Heap in use after garbage collection on a broker of ${var.name} over 60 % for 5 minutes."
    }
  }

  # One query per broker and metric, id m<broker>_<metric index>; the cluster-level metrics have one broker, 0.
  alarm_queries = {
    for k, a in local.alarms : k => flatten([
      for b in(a.per_broker ? local.broker_ids : [0]) : [
        for i, m in a.metrics : {
          id         = "m${b}_${i}"
          broker     = b
          metric     = m
          dimensions = b == 0 ? { "Cluster Name" = var.name } : { "Cluster Name" = var.name, "Broker ID" = tostring(b) }
        }
      ]
    ])
  }

  alarm_expressions = {
    for k, a in local.alarms : k => "MAX([${join(", ", [
      for b in(a.per_broker ? local.broker_ids : [0]) : join(" + ", [for i, _ in a.metrics : "m${b}_${i}"])
    ])}])"
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.severity == "page" ? "${each.value.summary} Runbook: ${local.runbook_base_url}/${each.key}.md" : each.value.summary
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  datapoints_to_alarm = each.value.datapoints
  evaluation_periods  = each.value.evaluation_periods
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  metric_query {
    id          = "e1"
    expression  = local.alarm_expressions[each.key]
    label       = each.key
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.alarm_queries[each.key]

    content {
      id = metric_query.value.id

      metric {
        namespace   = "AWS/Kafka"
        metric_name = metric_query.value.metric
        dimensions  = metric_query.value.dimensions
        stat        = each.value.statistic
        period      = 60
      }
    }
  }

  tags = {
    Severity = each.value.severity
  }

  lifecycle {
    precondition {
      condition     = length(local.alarm_queries[each.key]) <= 10
      error_message = "A CloudWatch alarm reads at most 10 metrics: ${each.key} would read ${length(local.alarm_queries[each.key])} with ${var.broker_count} brokers."
    }
  }
}
