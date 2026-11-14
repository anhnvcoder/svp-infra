# One PostgreSQL instance for every service: each service keeps its own database and roles on it, made by the
# bootstrap job of the cluster, so nothing here creates a database.
# Design notes: aws/modules/rds/README.md.

resource "aws_db_subnet_group" "this" {
  name_prefix = "${var.name}-"
  description = "Database subnets of ${var.name}"
  subnet_ids  = var.subnet_ids

  tags = {
    Name = var.name
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Reachable on 5432 from the given security groups only. No egress rule: the instance opens no connection itself, and
# Terraform removes the allow-all egress rule AWS puts on a new group.
resource "aws_security_group" "this" {
  name_prefix = "${var.name}-db-"
  description = "PostgreSQL ${var.name}, 5432 from the cluster only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-db"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = each.value
}

# Every connection must use TLS: a client that asks for plain text is refused at connect, so a missing sslmode in some
# service's URL fails loudly instead of sending passwords and rows in clear inside the VPC.
resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-pg${var.engine_major_version}-"
  description = "PostgreSQL ${var.engine_major_version} of ${var.name}, TLS only, slow statements and sessions logged"
  family      = "postgres${var.engine_major_version}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # What an incident needs to be read later: statements and autovacuum runs of 1 s or more, lock waits past
  # deadlock_timeout, temporary files of 10 MiB or more, every connection and session. Bind values stay out of the log
  # (log_parameter_max_length = 0): they carry e-mail addresses and password hashes.
  dynamic "parameter" {
    for_each = {
      log_min_duration_statement  = "1000"
      log_lock_waits              = "1"
      log_temp_files              = "10240"
      log_autovacuum_min_duration = "1000"
      log_connections             = "1"
      log_disconnections          = "1"
      log_parameter_max_length    = "0"
    }

    content {
      name  = parameter.key
      value = parameter.value
    }
  }

  # A new major means a new family, hence a new group, which must exist before the instance switches to it.
  lifecycle {
    create_before_destroy = true
  }
}

# One key of the instance for its storage, its Performance Insights data and the secret of its master password, so the
# env controls and audits every use of the data and can revoke it. Inside the account IAM decides who may use the key,
# as with the default key policy, and RDS uses it through grants it creates.
resource "aws_kms_key" "this" {
  description              = "RDS ${var.name}: storage, Performance Insights and master user secret"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 7
  policy                   = data.aws_iam_policy_document.key.json
}

# A snapshot encrypted with a customer managed key can be copied to another account only when that account may use the
# key: the backup account decrypts the snapshot and re-encrypts the copy with its own vault key, so the copy outlives
# this key. CreateGrant only for AWS resources: RDS of the backup account copies through a grant.
data "aws_iam_policy_document" "key" {
  statement {
    sid       = "EnableIamUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "BackupAccountUseForCopy"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.backup_account_root]
    }
  }

  statement {
    sid       = "BackupAccountGrantForCopy"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.backup_account_root]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

locals {
  backup_account_root = "arn:${data.aws_partition.current.partition}:iam::${var.backup_copy_account_id}:root"
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-rds"
  target_key_id = aws_kms_key.this.key_id
}

# A final snapshot needs a name no earlier snapshot holds: a production instance destroyed and made again would
# otherwise fail to delete. The suffix lives as long as the instance.
resource "random_id" "final_snapshot" {
  byte_length = 4
}

# Monitoring beyond what the cluster's Prometheus reads, each off by default (each adds cost, and enhanced monitoring
# an IAM role): CloudWatch Database Insights in Standard mode, the mode RDS enables by default and the one without the
# per-vCPU fee of Advanced (its 7 days of Performance Insights history are the free retention); enhanced monitoring
# (OS metrics every monitoring_interval seconds) through the role below; PostgreSQL logs exported to CloudWatch.
resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_major_version
  instance_class = var.instance_class

  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.this.arn

  # The CA RDS signs the server certificate with, written out so that a change of the RDS default shows in a plan:
  # clients verify the server against the bundle of this CA.
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  # The chart of the cluster expects this name for the bootstrap user (it carries only the password), on every
  # platform; it is the default master name of RDS PostgreSQL.
  username = "postgres"
  # RDS makes the password, keeps it in Secrets Manager and rotates it; it never passes through Terraform, so it is
  # in neither the plan nor the state.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  port                   = 5432
  multi_az               = var.multi_az

  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  backup_retention_period   = var.backup_retention_period
  delete_automated_backups  = var.delete_automated_backups
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final-${random_id.final_snapshot.hex}"

  database_insights_mode                = "standard"
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null
  performance_insights_kms_key_id       = var.performance_insights_enabled ? aws_kms_key.this.arn : null
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = var.monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null
  enabled_cloudwatch_logs_exports       = var.cloudwatch_logs_exports

  # Backup = daily puts the instance in the selection of the organization's backup policy.
  tags = {
    Name   = var.name
    Backup = "daily"
  }

  # RDS creates the log group of an export, and the one of enhanced monitoring, itself when it does not exist yet,
  # outside the state; made first here, each group keeps the retention below and goes away with terraform destroy.
  depends_on = [aws_cloudwatch_log_group.this, aws_cloudwatch_log_group.os_metrics]
}

# The group RDS writes each exported log to: /aws/rds/instance/<identifier>/<log type>.
resource "aws_cloudwatch_log_group" "this" {
  for_each = toset(var.cloudwatch_logs_exports)

  name              = "/aws/rds/instance/${var.name}/${each.key}"
  retention_in_days = var.cloudwatch_logs_retention_days
}

# The group enhanced monitoring writes OS metrics to, one log stream per instance. RDS fixes its name and shares it
# across the account and region, so this module expects to be the only one with monitoring on (one instance per env
# account). Left to RDS, it would keep 30 days of metrics after the instance is gone
# (https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_Monitoring.OS.html, read 2026-11-05).
resource "aws_cloudwatch_log_group" "os_metrics" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name              = "RDSOSMetrics"
  retention_in_days = var.cloudwatch_logs_retention_days
}

data "aws_partition" "current" {}

data "aws_region" "current" {
  count = var.monitoring_interval > 0 ? 1 : 0
}

data "aws_caller_identity" "current" {}

# The role enhanced monitoring assumes to write OS metrics to CloudWatch Logs. The trust policy is the one of the RDS
# guide, with both confused deputy conditions: only RDS acting for this instance, in this account, may assume it
# (https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_Monitoring.OS.Enabling.html).
resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name        = "${var.name}-rds-monitoring"
  description = "Enhanced monitoring of RDS instance ${var.name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringLike   = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:rds:${data.aws_region.current[0].region}:${data.aws_caller_identity.current.account_id}:db:${var.name}" }
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

# The AWS managed policy of enhanced monitoring: create and write the RDSOSMetrics log group only.
resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
