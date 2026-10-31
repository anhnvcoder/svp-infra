# One PostgreSQL instance for every service: each service keeps its own database and roles on it, made by the
# bootstrap job of the cluster, so nothing here creates a database.

resource "aws_db_subnet_group" "this" {
  name_prefix = "${var.name}-"
  description = "Private subnets of ${var.name}"
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
  description = "PostgreSQL ${var.engine_major_version} of ${var.name}, TLS only"
  family      = "postgres${var.engine_major_version}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # A new major means a new family, hence a new group, which must exist before the instance switches to it.
  lifecycle {
    create_before_destroy = true
  }
}

# A final snapshot needs a name no earlier snapshot holds: a production instance destroyed and made again would
# otherwise fail to delete. The suffix lives as long as the instance.
resource "random_id" "final_snapshot" {
  byte_length = 4
}

# Performance Insights and enhanced monitoring stay off: the cluster's Prometheus and the database's own views are
# what the lab reads, and both add cost and an IAM role.
resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_major_version
  instance_class = var.instance_class

  storage_type      = "gp3"
  allocated_storage = var.allocated_storage
  # Encrypted with the AWS managed key of RDS: no key of our own to pay for and keep a policy on.
  storage_encrypted = true

  # The chart of the cluster expects this name for the bootstrap user (it carries only the password), on every
  # platform; it is the default master name of RDS PostgreSQL.
  username = "postgres"
  # RDS makes the password, keeps it in Secrets Manager and rotates it; it never passes through Terraform, so it is
  # in neither the plan nor the state.
  manage_master_user_password = true

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

  performance_insights_enabled = false
  monitoring_interval          = 0

  tags = {
    Name = var.name
  }
}
