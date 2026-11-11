# Validation rules of the module's variables: one plan with valid values, then one plan per rule with a value that only
# that rule rejects; then what the defaults keep, what each monitoring variable adds, and the values of stg and prd. The
# AWS provider is a mock: nothing reaches an account, and data sources return the values below (the provider still
# validates arguments, so ARNs must be well formed). Plans only, so attributes the provider computes, such as the ARN
# of the module's KMS key, stay unknown: the assertions read what the module sets.

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
}

variables {
  name                    = "svp-stg"
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_ids              = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  allowed_security_groups = { node = "sg-0123456789abcdef0" }
  deletion_protection     = false
  skip_final_snapshot     = true
  alarm_topic_arn         = "arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"
}

run "valid" {
  command = plan
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
    subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
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

run "engine_major_version_minor" {
  command = plan

  variables {
    engine_major_version = "17.4"
  }

  expect_failures = [var.engine_major_version]
}

run "allocated_storage_below_minimum" {
  command = plan

  variables {
    allocated_storage = 10
  }

  expect_failures = [var.allocated_storage]
}

run "instance_class_without_thresholds" {
  command = plan

  variables {
    instance_class = "db.t4g.medium"
  }

  expect_failures = [var.instance_class]
}

run "max_allocated_storage_not_above_allocated" {
  command = plan

  variables {
    max_allocated_storage = 20
  }

  expect_failures = [var.max_allocated_storage]
}

run "max_allocated_storage_under_26_percent_above" {
  command = plan

  variables {
    allocated_storage     = 100
    max_allocated_storage = 120
  }

  expect_failures = [var.max_allocated_storage]
}

run "alarm_topic_arn_not_sns" {
  command = plan

  variables {
    alarm_topic_arn = "arn:aws:sqs:ap-southeast-1:000000000000:svp-stg-alarms"
  }

  expect_failures = [var.alarm_topic_arn]
}

run "backup_retention_period_zero" {
  command = plan

  variables {
    backup_retention_period = 0
  }

  expect_failures = [var.backup_retention_period]
}

run "performance_insights_retention_period_not_offered" {
  command = plan

  variables {
    performance_insights_retention_period = 30
  }

  expect_failures = [var.performance_insights_retention_period]
}

run "monitoring_interval_not_offered" {
  command = plan

  variables {
    monitoring_interval = 2
  }

  expect_failures = [var.monitoring_interval]
}

run "cloudwatch_logs_exports_unknown" {
  command = plan

  variables {
    cloudwatch_logs_exports = ["audit"]
  }

  expect_failures = [var.cloudwatch_logs_exports]
}

run "cloudwatch_logs_retention_days_not_offered" {
  command = plan

  variables {
    cloudwatch_logs_retention_days = 2
  }

  expect_failures = [var.cloudwatch_logs_retention_days]
}

# The defaults keep the instance as it was before the monitoring variables existed: no Performance Insights, no
# enhanced monitoring and no IAM role, no log export and no log group, one zone, backups deleted with the instance.
run "defaults" {
  command = plan

  assert {
    condition     = aws_db_instance.this.performance_insights_enabled == false && aws_db_instance.this.monitoring_interval == 0
    error_message = "By default Performance Insights and enhanced monitoring must stay off."
  }

  assert {
    condition     = length(aws_iam_role.monitoring) == 0 && length(aws_iam_role_policy_attachment.monitoring) == 0 && length(aws_cloudwatch_log_group.os_metrics) == 0
    error_message = "By default the module must create no monitoring role and no OS metrics log group."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.this) == 0 && length(aws_db_instance.this.enabled_cloudwatch_logs_exports) == 0
    error_message = "By default no log may be exported and no log group created."
  }

  assert {
    condition     = aws_db_instance.this.instance_class == "db.t4g.small" && aws_db_instance.this.multi_az == false && aws_db_instance.this.backup_retention_period == 1 && aws_db_instance.this.delete_automated_backups == true
    error_message = "The defaults of size and backups must stay those of the lab."
  }
}

run "performance_insights_on" {
  command = plan

  variables {
    performance_insights_enabled = true
  }

  assert {
    condition     = aws_db_instance.this.performance_insights_enabled == true && aws_db_instance.this.performance_insights_retention_period == 7 && aws_db_instance.this.database_insights_mode == "standard"
    error_message = "performance_insights_enabled = true must turn Performance Insights on with the free 7 days, in Database Insights Standard mode."
  }
}

run "monitoring_on" {
  command = plan

  variables {
    monitoring_interval = 60
  }

  assert {
    condition     = aws_db_instance.this.monitoring_interval == 60 && length(aws_iam_role.monitoring) == 1
    error_message = "monitoring_interval = 60 must sample every 60 seconds through a role of the module."
  }

  assert {
    condition     = jsondecode(aws_iam_role.monitoring[0].assume_role_policy).Statement[0].Principal.Service == "monitoring.rds.amazonaws.com"
    error_message = "Only the enhanced monitoring service may assume the monitoring role."
  }

  assert {
    condition     = jsondecode(aws_iam_role.monitoring[0].assume_role_policy).Statement[0].Condition.StringLike["aws:SourceArn"] == "arn:aws:rds:ap-southeast-1:000000000000:db:svp-stg"
    error_message = "The monitoring role must trust RDS only for this instance."
  }

  assert {
    condition     = jsondecode(aws_iam_role.monitoring[0].assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "000000000000"
    error_message = "The monitoring role must trust RDS only for this account."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.monitoring[0].policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
    error_message = "The monitoring role must carry the AWS managed policy of enhanced monitoring and nothing else."
  }

  assert {
    condition     = aws_cloudwatch_log_group.os_metrics[0].name == "RDSOSMetrics" && aws_cloudwatch_log_group.os_metrics[0].retention_in_days == 1
    error_message = "Enhanced monitoring must write to the RDSOSMetrics group made here, with the retention of the module, so that destroy removes it."
  }
}

run "log_exports_on" {
  command = plan

  variables {
    cloudwatch_logs_exports        = ["postgresql"]
    cloudwatch_logs_retention_days = 7
  }

  assert {
    condition     = aws_cloudwatch_log_group.this["postgresql"].name == "/aws/rds/instance/svp-stg/postgresql" && aws_cloudwatch_log_group.this["postgresql"].retention_in_days == 7
    error_message = "An exported log must go to the group RDS writes to, made here with its retention."
  }

  assert {
    condition     = contains(aws_db_instance.this.enabled_cloudwatch_logs_exports, "postgresql")
    error_message = "The instance must export the postgresql log."
  }
}

# Values of the stg root: one zone, the stg class, and what stg shares with prd: PostgreSQL 17, the module's own KMS
# key, the pinned CA, TLS only, the logging parameters and every alarm.
run "stg_values" {
  command = plan

  variables {
    max_allocated_storage          = 40
    performance_insights_enabled   = true
    monitoring_interval            = 60
    cloudwatch_logs_exports        = ["postgresql", "upgrade"]
    cloudwatch_logs_retention_days = 1
  }

  assert {
    condition     = aws_db_instance.this.instance_class == "db.t4g.small" && aws_db_instance.this.multi_az == false
    error_message = "stg must run one db.t4g.small instance in one zone."
  }

  assert {
    condition     = aws_db_instance.this.engine_version == "17" && aws_db_parameter_group.this.family == "postgres17"
    error_message = "stg must run PostgreSQL 17 with a postgres17 parameter group."
  }

  assert {
    condition     = aws_db_instance.this.allocated_storage == 20 && aws_db_instance.this.max_allocated_storage == 40
    error_message = "stg must grow its 20 GiB volume by storage autoscaling up to 40 GiB."
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == true && aws_kms_key.this.deletion_window_in_days == 7 && aws_kms_key.this.customer_master_key_spec == "SYMMETRIC_DEFAULT" && aws_kms_key.this.key_usage == "ENCRYPT_DECRYPT"
    error_message = "The module must make its own symmetric KMS key, rotated, with the shortest deletion window."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true && aws_db_instance.this.manage_master_user_password == true && aws_db_instance.this.performance_insights_enabled == true
    error_message = "stg must encrypt its storage, keep its master password in Secrets Manager and keep Performance Insights, all under the key of the module."
  }

  assert {
    condition     = aws_db_instance.this.ca_cert_identifier == "rds-ca-rsa2048-g1"
    error_message = "The server certificate must be signed by rds-ca-rsa2048-g1, the CA whose bundle the clients trust."
  }

  assert {
    condition = { for p in aws_db_parameter_group.this.parameter : p.name => p.value } == {
      "rds.force_ssl"             = "1"
      log_min_duration_statement  = "1000"
      log_lock_waits              = "1"
      log_temp_files              = "10240"
      log_autovacuum_min_duration = "1000"
      log_connections             = "1"
      log_disconnections          = "1"
      log_parameter_max_length    = "0"
    }
    error_message = "The parameter group must refuse plain text connections and log slow statements, lock waits, temporary files, autovacuum and sessions, without bind values."
  }

  assert {
    condition     = toset(keys(aws_cloudwatch_metric_alarm.this)) == toset(["rds-storage-low", "rds-txid-wraparound", "rds-cpu-high", "rds-memory-low", "rds-connections-high", "rds-db-load-high", "rds-read-latency-high", "rds-write-latency-high"])
    error_message = "The module must make every alarm of the RDS table, and no other."
  }

  assert {
    condition     = alltrue([for k, a in aws_cloudwatch_metric_alarm.this : a.alarm_name == "svp-stg-${k}" && a.namespace == "AWS/RDS" && a.dimensions["DBInstanceIdentifier"] == "svp-stg" && length(a.dimensions) == 1 && a.period == 60])
    error_message = "Every alarm must be named <name>-<alarm> and read its metric of this instance every 60 seconds."
  }

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.this : a.alarm_actions == toset(["arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"]) && a.ok_actions == toset(["arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"])])
    error_message = "Every alarm must notify the alarm topic when it fires and when it clears."
  }

  assert {
    condition     = alltrue([for k, a in aws_cloudwatch_metric_alarm.this : contains(["rds-storage-low", "rds-txid-wraparound"], k) ? a.tags["Severity"] == "page" && strcontains(a.alarm_description, "https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/${k}.md") : a.tags["Severity"] == "ticket" && !strcontains(a.alarm_description, "runbooks")])
    error_message = "The storage and wraparound alarms must page with the URL of their runbook; every other alarm is a ticket."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["rds-storage-low"].threshold == 2147483648 && aws_cloudwatch_metric_alarm.this["rds-storage-low"].statistic == "Minimum" && aws_cloudwatch_metric_alarm.this["rds-storage-low"].comparison_operator == "LessThanThreshold" && aws_cloudwatch_metric_alarm.this["rds-storage-low"].datapoints_to_alarm == 15 && aws_cloudwatch_metric_alarm.this["rds-storage-low"].evaluation_periods == 15
    error_message = "rds-storage-low must fire when free storage stays under 10 % of 20 GiB for 15 of 15 minutes."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["rds-txid-wraparound"].threshold == 1000000000 && aws_cloudwatch_metric_alarm.this["rds-txid-wraparound"].datapoints_to_alarm == 1 && aws_cloudwatch_metric_alarm.this["rds-txid-wraparound"].evaluation_periods == 1
    error_message = "rds-txid-wraparound must fire on the first minute over one billion transaction IDs."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["rds-memory-low"].threshold == 536870912 && aws_cloudwatch_metric_alarm.this["rds-connections-high"].threshold == 186 && aws_cloudwatch_metric_alarm.this["rds-db-load-high"].threshold == 2
    error_message = "The class thresholds of stg must be 512 MiB of freeable memory, 186 connections and a load of 2."
  }

  assert {
    condition     = alltrue([for k in ["rds-read-latency-high", "rds-write-latency-high"] : aws_cloudwatch_metric_alarm.this[k].extended_statistic == "p90" && aws_cloudwatch_metric_alarm.this[k].statistic == null && aws_cloudwatch_metric_alarm.this[k].threshold == 0.02])
    error_message = "The latency alarms must read the p90 against 20 ms."
  }
}

# Values of the prd root: the protections of production data and its monitoring.
run "prd_values" {
  command = plan

  variables {
    name                           = "svp-prd"
    instance_class                 = "db.m7g.large"
    max_allocated_storage          = 100
    alarm_topic_arn                = "arn:aws:sns:ap-southeast-1:000000000000:svp-prd-alarms"
    multi_az                       = true
    backup_retention_period        = 7
    delete_automated_backups       = false
    deletion_protection            = true
    skip_final_snapshot            = false
    performance_insights_enabled   = true
    monitoring_interval            = 60
    cloudwatch_logs_exports        = ["postgresql", "upgrade"]
    cloudwatch_logs_retention_days = 30
  }

  assert {
    condition     = aws_db_instance.this.multi_az == true && aws_db_instance.this.deletion_protection == true && aws_db_instance.this.skip_final_snapshot == false
    error_message = "prd must run Multi-AZ, refuse deletion and take a final snapshot."
  }

  assert {
    condition     = aws_db_instance.this.backup_retention_period == 7 && aws_db_instance.this.delete_automated_backups == false
    error_message = "prd must keep 7 days of backups, also after the instance is deleted."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true && aws_db_instance.this.publicly_accessible == false
    error_message = "prd must keep the storage encrypted and the instance private."
  }

  assert {
    condition     = aws_db_instance.this.performance_insights_enabled == true && aws_db_instance.this.database_insights_mode == "standard" && aws_db_instance.this.monitoring_interval == 60 && length(aws_iam_role.monitoring) == 1
    error_message = "prd must run Performance Insights in Database Insights Standard mode and enhanced monitoring every 60 seconds."
  }

  assert {
    condition     = toset(keys(aws_cloudwatch_log_group.this)) == toset(["postgresql", "upgrade"]) && alltrue([for g in aws_cloudwatch_log_group.this : g.retention_in_days == 30])
    error_message = "prd must export the postgresql and upgrade logs into log groups with a retention."
  }

  assert {
    condition     = aws_cloudwatch_log_group.os_metrics[0].name == "RDSOSMetrics" && aws_cloudwatch_log_group.os_metrics[0].retention_in_days == 30
    error_message = "prd must keep its OS metrics in the RDSOSMetrics group made here, with the retention of its logs."
  }

  assert {
    condition     = aws_db_instance.this.instance_class == "db.m7g.large" && aws_db_instance.this.max_allocated_storage == 100
    error_message = "prd must run db.m7g.large and grow its volume by storage autoscaling up to 100 GiB."
  }

  assert {
    condition     = aws_db_instance.this.engine_version == "17" && aws_db_parameter_group.this.family == "postgres17" && aws_db_instance.this.ca_cert_identifier == "rds-ca-rsa2048-g1"
    error_message = "prd must run PostgreSQL 17 with the CA the clients trust."
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == true && aws_kms_key.this.customer_master_key_spec == "SYMMETRIC_DEFAULT"
    error_message = "prd must encrypt under a symmetric, rotated KMS key of the module."
  }

  assert {
    condition     = contains([for p in aws_db_parameter_group.this.parameter : "${p.name}=${p.value}"], "rds.force_ssl=1") && contains([for p in aws_db_parameter_group.this.parameter : "${p.name}=${p.value}"], "log_parameter_max_length=0")
    error_message = "prd must refuse plain text connections and keep bind values out of the log."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.this) == 8 && alltrue([for k, a in aws_cloudwatch_metric_alarm.this : a.alarm_name == "svp-prd-${k}" && a.dimensions["DBInstanceIdentifier"] == "svp-prd" && length(a.dimensions) == 1 && a.alarm_actions == toset(["arn:aws:sns:ap-southeast-1:000000000000:svp-prd-alarms"]) && a.ok_actions == toset(["arn:aws:sns:ap-southeast-1:000000000000:svp-prd-alarms"])])
    error_message = "prd must have every alarm of the table, named svp-prd-<alarm>, on its instance, notifying its own alarm topic."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["rds-memory-low"].threshold == 2147483648 && aws_cloudwatch_metric_alarm.this["rds-connections-high"].threshold == 745 && aws_cloudwatch_metric_alarm.this["rds-db-load-high"].threshold == 2
    error_message = "The class thresholds of prd must be 2 GiB of freeable memory, 745 connections and a load of 2."
  }
}
