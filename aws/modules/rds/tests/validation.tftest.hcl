# Validation rules of the module's variables: one plan with valid values, then one plan per rule with a value that only
# that rule rejects; then what the defaults keep, what each monitoring variable adds, and the values of prd. The AWS
# provider is a mock: nothing reaches an account, and data sources return the values below (the provider still
# validates arguments, so ARNs must be well formed).

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
    engine_major_version = "15.4"
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

# Values of the prd root: the protections of production data and its monitoring.
run "prd_values" {
  command = plan

  variables {
    name                           = "svp-prd"
    instance_class                 = "db.t4g.medium"
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
}
