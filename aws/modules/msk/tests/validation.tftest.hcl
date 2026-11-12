# Validation rules of the module's variables, then the protections of the cluster with the values of stg and of prd.
# The AWS provider is a mock: nothing reaches an account (the provider still validates arguments, so ARNs must be well
# formed). Plans only, so attributes the provider computes stay unknown: the assertions read what the module sets.

mock_provider "aws" {}

variables {
  name                    = "svp-stg"
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_ids              = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  allowed_security_groups = { node = "sg-0123456789abcdef0", cluster = "sg-0fedcba9876543210" }
  broker_count            = 2
  replication_factor      = 2
  min_insync_replicas     = 1
  kafka_admin_secret_id   = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp/stg/kafka-admin-AbCdEf"
  kafka_users_secret_id   = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp/stg/kafka-users-AbCdEf"
  broker_volume_max_size  = 20
  alarm_topic_arn         = "arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"
}

# Values of the stg root: two brokers in two zones, replication 2, minimum ISR 1, no broker logs.
run "stg_values" {
  command = plan

  assert {
    condition     = aws_msk_cluster.this.client_authentication[0].unauthenticated == false
    error_message = "The cluster must refuse unauthenticated clients."
  }

  assert {
    condition     = aws_msk_cluster.this.client_authentication[0].sasl[0].scram == true && aws_msk_cluster.this.client_authentication[0].sasl[0].iam == false && length(aws_msk_cluster.this.client_authentication[0].tls) == 0
    error_message = "SASL/SCRAM must be the only client authentication."
  }

  assert {
    condition     = aws_msk_cluster.this.encryption_info[0].encryption_in_transit[0].client_broker == "TLS" && aws_msk_cluster.this.encryption_info[0].encryption_in_transit[0].in_cluster == true
    error_message = "Traffic must be TLS only, between clients and brokers and inside the cluster."
  }

  assert {
    condition     = aws_msk_cluster.this.kafka_version == "4.1.x.kraft" && aws_msk_cluster.this.number_of_broker_nodes == 2 && aws_msk_cluster.this.broker_node_group_info[0].instance_type == "kafka.t3.small"
    error_message = "stg must run two kafka.t3.small brokers on Kafka 4.1 in KRaft mode."
  }

  assert {
    condition = toset(split("\n", aws_msk_configuration.this.server_properties)) == toset([
      "allow.everyone.if.no.acl.found=true",
      "auto.create.topics.enable=false",
      "default.replication.factor=2",
      "min.insync.replicas=1",
      "offsets.topic.replication.factor=2",
      "transaction.state.log.min.isr=1",
      "transaction.state.log.replication.factor=2",
      "unclean.leader.election.enable=false",
    ])
    error_message = "The configuration of stg must turn topic auto-creation off and replicate 2, with a minimum ISR of 1, internal topics included."
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == true && aws_kms_key.this.deletion_window_in_days == 7
    error_message = "The module must make its own KMS key, rotated, with the shortest deletion window."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.scram) == 8 && alltrue([for u, s in aws_secretsmanager_secret.scram : s.name == "AmazonMSK_svp-stg-${u}" && startswith(s.name, "AmazonMSK_")])
    error_message = "Every Kafka user must have a secret named AmazonMSK_<name>-<user>."
  }

  # MSK refuses a secret under the AWS managed key of Secrets Manager or an asymmetric key. Which key each secret names
  # (aws_kms_key.this.arn) is only known after apply, so the plan checks the kind of key the module makes.
  assert {
    condition     = aws_kms_key.this.customer_master_key_spec == "SYMMETRIC_DEFAULT" && aws_kms_key.this.key_usage == "ENCRYPT_DECRYPT"
    error_message = "The key of the SCRAM secrets must be a symmetric encryption key of the module."
  }

  assert {
    condition     = alltrue([for s in aws_secretsmanager_secret_version.scram : s.secret_string_wo_version == 1]) && aws_secretsmanager_secret_version.kafka_admin.secret_string_wo_version == 1 && aws_secretsmanager_secret_version.kafka_users.secret_string_wo_version == 1
    error_message = "The SCRAM secrets and the two entries must be written with the same password version."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.kafka_admin.secret_id == var.kafka_admin_secret_id && aws_secretsmanager_secret_version.kafka_users.secret_id == var.kafka_users_secret_id
    error_message = "The passwords must be written into the entries kafka-admin and kafka-users given to the module."
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.scram)) == toset(["node", "cluster"]) && alltrue([for r in aws_vpc_security_group_ingress_rule.scram : r.ip_protocol == "tcp" && r.from_port == 9096 && r.to_port == 9096 && r.cidr_ipv4 == null])
    error_message = "The security group must open TCP 9096 only, from the given security groups only."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.this) == 0 && aws_msk_cluster.this.logging_info[0].broker_logs[0].cloudwatch_logs[0].enabled == false
    error_message = "By default the brokers must send no log and the module must create no log group."
  }

  assert {
    condition     = aws_appautoscaling_target.storage.service_namespace == "kafka" && aws_appautoscaling_target.storage.scalable_dimension == "kafka:broker-storage:VolumeSize" && aws_appautoscaling_target.storage.min_capacity == 10 && aws_appautoscaling_target.storage.max_capacity == 20
    error_message = "Storage autoscaling of stg must grow the broker volumes from 10 GiB up to 20 GiB."
  }

  assert {
    condition = (
      aws_appautoscaling_policy.storage.policy_type == "TargetTrackingScaling" &&
      aws_appautoscaling_policy.storage.target_tracking_scaling_policy_configuration[0].predefined_metric_specification[0].predefined_metric_type == "KafkaBrokerStorageUtilization" &&
      aws_appautoscaling_policy.storage.target_tracking_scaling_policy_configuration[0].target_value == 60 &&
      aws_appautoscaling_policy.storage.target_tracking_scaling_policy_configuration[0].disable_scale_in == true
    )
    error_message = "The storage policy must track KafkaBrokerStorageUtilization at 60 %, never scaling in."
  }

  assert {
    condition     = toset(keys(aws_cloudwatch_metric_alarm.this)) == toset(["msk-disk-high", "msk-offline-partitions", "msk-under-min-isr", "msk-under-replicated", "msk-cpu-high", "msk-heap-high"]) && alltrue([for k, a in aws_cloudwatch_metric_alarm.this : a.alarm_name == "svp-stg-${k}"])
    error_message = "stg must have every MSK alarm of the table, named svp-stg-<alarm>."
  }

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.this : a.alarm_actions == toset([var.alarm_topic_arn]) && a.ok_actions == toset([var.alarm_topic_arn])])
    error_message = "Every alarm must notify the alarm topic when it fires and when it clears."
  }

  assert {
    condition = alltrue([
      for k, a in aws_cloudwatch_metric_alarm.this : a.tags["Severity"] == (contains(["msk-disk-high", "msk-offline-partitions", "msk-under-min-isr"], k) ? "page" : "ticket") && (
        a.tags["Severity"] == "page" ? strcontains(a.alarm_description, "https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/${k}.md") : !strcontains(a.alarm_description, "Runbook")
      )
    ])
    error_message = "Disk, offline partitions and under min ISR must page with the URL of their runbook; the other alarms are tickets."
  }

  # Per-broker alarms read both brokers by ID and take the highest; offline partitions is a cluster metric.
  assert {
    condition = (
      toset([for q in aws_cloudwatch_metric_alarm.this["msk-disk-high"].metric_query : q.metric[0].dimensions["Broker ID"] if q.return_data != true]) == toset(["1", "2"]) &&
      alltrue([for q in aws_cloudwatch_metric_alarm.this["msk-disk-high"].metric_query : q.metric[0].dimensions["Cluster Name"] == "svp-stg" && q.metric[0].namespace == "AWS/Kafka" && q.metric[0].period == 60 && q.metric[0].stat == "Maximum" if q.return_data != true]) &&
      one([for q in aws_cloudwatch_metric_alarm.this["msk-disk-high"].metric_query : q.expression if q.return_data == true]) == "MAX([m1_0, m2_0])"
    )
    error_message = "msk-disk-high must take the highest disk use of the two brokers of stg."
  }

  assert {
    condition     = one([for q in aws_cloudwatch_metric_alarm.this["msk-cpu-high"].metric_query : q.expression if q.return_data == true]) == "MAX([m1_0 + m1_1, m2_0 + m2_1])" && length(aws_cloudwatch_metric_alarm.this["msk-cpu-high"].metric_query) == 5
    error_message = "msk-cpu-high must add user and system CPU of each broker, then take the highest."
  }

  assert {
    condition     = one([for q in aws_cloudwatch_metric_alarm.this["msk-offline-partitions"].metric_query : q.metric[0].dimensions if q.return_data != true]) == tomap({ "Cluster Name" = "svp-stg" })
    error_message = "msk-offline-partitions must read the cluster-level metric."
  }

  assert {
    condition     = alltrue([for k, a in aws_cloudwatch_metric_alarm.this : a.evaluation_periods == a.datapoints_to_alarm]) && aws_cloudwatch_metric_alarm.this["msk-disk-high"].threshold == 85 && aws_cloudwatch_metric_alarm.this["msk-disk-high"].comparison_operator == "GreaterThanOrEqualToThreshold" && aws_cloudwatch_metric_alarm.this["msk-under-replicated"].evaluation_periods == 15 && aws_cloudwatch_metric_alarm.this["msk-offline-partitions"].evaluation_periods == 1
    error_message = "The levels and periods of the alarms must be those of the table."
  }
}

# Values of the prd root: three brokers in three zones, replication 3, minimum ISR 2, broker logs kept 30 days.
run "prd_values" {
  command = plan

  variables {
    name                       = "svp-prd"
    subnet_ids                 = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2", "subnet-0ccccccccccccccc3"]
    broker_count               = 3
    broker_instance_type       = "kafka.m7g.large"
    replication_factor         = 3
    min_insync_replicas        = 2
    broker_logs_enabled        = true
    broker_logs_retention_days = 30
    kafka_admin_secret_id      = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp/prd/kafka-admin-AbCdEf"
    kafka_users_secret_id      = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp/prd/kafka-users-AbCdEf"
    password_version           = 3
    broker_volume_max_size     = 100
    alarm_topic_arn            = "arn:aws:sns:ap-southeast-1:000000000000:svp-prd-alarms"
  }

  assert {
    condition     = aws_msk_cluster.this.client_authentication[0].unauthenticated == false && aws_msk_cluster.this.client_authentication[0].sasl[0].scram == true && aws_msk_cluster.this.client_authentication[0].sasl[0].iam == false
    error_message = "prd must accept SASL/SCRAM clients only."
  }

  assert {
    condition     = aws_msk_cluster.this.encryption_info[0].encryption_in_transit[0].client_broker == "TLS" && aws_msk_cluster.this.encryption_info[0].encryption_in_transit[0].in_cluster == true
    error_message = "prd traffic must be TLS only."
  }

  assert {
    condition     = aws_msk_cluster.this.number_of_broker_nodes == 3 && aws_msk_cluster.this.broker_node_group_info[0].instance_type == "kafka.m7g.large" && length(aws_msk_cluster.this.broker_node_group_info[0].client_subnets) == 3
    error_message = "prd must run three kafka.m7g.large brokers, one per zone."
  }

  assert {
    condition = toset(split("\n", aws_msk_configuration.this.server_properties)) == toset([
      "allow.everyone.if.no.acl.found=true",
      "auto.create.topics.enable=false",
      "default.replication.factor=3",
      "min.insync.replicas=2",
      "offsets.topic.replication.factor=3",
      "transaction.state.log.min.isr=2",
      "transaction.state.log.replication.factor=3",
      "unclean.leader.election.enable=false",
    ])
    error_message = "The configuration of prd must replicate 3 with a minimum ISR of 2, internal topics included, so that losing a zone loses no acknowledged write."
  }

  assert {
    condition     = alltrue([for u, s in aws_secretsmanager_secret.scram : s.name == "AmazonMSK_svp-prd-${u}"])
    error_message = "The SCRAM secrets of prd must be named AmazonMSK_svp-prd-<user>."
  }

  # A version other than the default: every write takes the one given, not a fixed number.
  assert {
    condition     = alltrue([for s in aws_secretsmanager_secret_version.scram : s.secret_string_wo_version == 3]) && aws_secretsmanager_secret_version.kafka_admin.secret_string_wo_version == 3 && aws_secretsmanager_secret_version.kafka_users.secret_string_wo_version == 3
    error_message = "The SCRAM secrets and the two entries must be written with the password version given to the module."
  }

  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.scram : r.from_port == 9096 && r.to_port == 9096 && r.ip_protocol == "tcp"])
    error_message = "The security group of prd must open TCP 9096 only."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this[0].name == "/aws/msk/svp-prd" && aws_cloudwatch_log_group.this[0].retention_in_days == 30 && aws_msk_cluster.this.logging_info[0].broker_logs[0].cloudwatch_logs[0].enabled == true
    error_message = "prd must send the broker logs to /aws/msk/svp-prd, kept 30 days."
  }

  assert {
    condition     = aws_appautoscaling_target.storage.min_capacity == 10 && aws_appautoscaling_target.storage.max_capacity == 100 && aws_appautoscaling_policy.storage.target_tracking_scaling_policy_configuration[0].target_value == 60 && aws_appautoscaling_policy.storage.target_tracking_scaling_policy_configuration[0].disable_scale_in == true
    error_message = "Storage autoscaling of prd must grow the broker volumes from 10 GiB up to 100 GiB, never scaling in."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.this) == 6 && alltrue([for k, a in aws_cloudwatch_metric_alarm.this : a.alarm_name == "svp-prd-${k}" && a.alarm_actions == toset([var.alarm_topic_arn]) && a.ok_actions == toset([var.alarm_topic_arn])])
    error_message = "prd must have every MSK alarm, named svp-prd-<alarm>, notifying the alarm topic of prd."
  }

  assert {
    condition     = toset([for q in aws_cloudwatch_metric_alarm.this["msk-under-min-isr"].metric_query : q.metric[0].dimensions["Broker ID"] if q.return_data != true]) == toset(["1", "2", "3"]) && one([for q in aws_cloudwatch_metric_alarm.this["msk-cpu-high"].metric_query : q.expression if q.return_data == true]) == "MAX([m1_0 + m1_1, m2_0 + m2_1, m3_0 + m3_1])"
    error_message = "The per-broker alarms of prd must read the three brokers."
  }
}

run "name_double_hyphen" {
  command = plan

  variables {
    name = "svp--stg"
  }

  expect_failures = [var.name]
}

run "subnet_ids_one_zone" {
  command = plan

  variables {
    subnet_ids         = ["subnet-0aaaaaaaaaaaaaaa1"]
    broker_count       = 1
    replication_factor = 1
  }

  expect_failures = [var.subnet_ids]
}

run "allowed_security_groups_empty" {
  command = plan

  variables {
    allowed_security_groups = {}
  }

  expect_failures = [var.allowed_security_groups]
}

run "kafka_version_zookeeper" {
  command = plan

  variables {
    kafka_version = "3.9.x"
  }

  expect_failures = [var.kafka_version]
}

run "broker_instance_type_not_msk" {
  command = plan

  variables {
    broker_instance_type = "t3.small"
  }

  expect_failures = [var.broker_instance_type]
}

run "broker_count_not_multiple_of_subnets" {
  command = plan

  variables {
    broker_count       = 3
    replication_factor = 2
  }

  expect_failures = [var.broker_count]
}

run "broker_volume_size_zero" {
  command = plan

  variables {
    broker_volume_size = 0
  }

  expect_failures = [var.broker_volume_size]
}

run "replication_factor_above_broker_count" {
  command = plan

  variables {
    replication_factor = 3
  }

  expect_failures = [var.replication_factor]
}

run "min_insync_replicas_equal_to_replication_factor" {
  command = plan

  variables {
    min_insync_replicas = 2
  }

  expect_failures = [var.min_insync_replicas]
}

run "min_insync_replicas_above_one_with_replication_one" {
  command = plan

  variables {
    replication_factor  = 1
    min_insync_replicas = 2
  }

  expect_failures = [var.min_insync_replicas]
}

run "broker_logs_retention_days_not_offered" {
  command = plan

  variables {
    broker_logs_retention_days = 2
  }

  expect_failures = [var.broker_logs_retention_days]
}

run "password_version_zero" {
  command = plan

  variables {
    password_version = 0
  }

  expect_failures = [var.password_version]
}

run "broker_volume_max_size_below_volume_size" {
  command = plan

  variables {
    broker_volume_max_size = 5
  }

  expect_failures = [var.broker_volume_max_size]
}

run "broker_storage_target_utilization_full" {
  command = plan

  variables {
    broker_storage_target_utilization = 100
  }

  expect_failures = [var.broker_storage_target_utilization]
}

run "alarm_topic_arn_not_sns" {
  command = plan

  variables {
    alarm_topic_arn = "arn:aws:sqs:ap-southeast-1:000000000000:svp-stg-alarms"
  }

  expect_failures = [var.alarm_topic_arn]
}

# Six brokers would make the CPU alarm read 12 metrics, over the 10 an alarm allows.
run "alarm_over_ten_metrics" {
  command = plan

  variables {
    subnet_ids         = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2", "subnet-0ccccccccccccccc3"]
    broker_count       = 6
    replication_factor = 3
  }

  expect_failures = [aws_cloudwatch_metric_alarm.this["msk-cpu-high"]]
}
