# One Amazon MSK provisioned cluster per env: KRaft brokers reached only over SASL/SCRAM-SHA-512 on TLS (port 9096), one
# SCRAM user per client, passwords made and written in the same apply without passing through plan or state.
# Design notes: aws/modules/msk/README.md.

locals {
  # The Kafka users of the platform. svp-admin creates topics and ACLs (the init job); every other user gets only the
  # ACLs that job grants it.
  users = toset([
    "svp-admin",
    "svp-user-service",
    "svp-video-service",
    "svp-engagement-service",
    "svp-feed-service",
    "svp-media-worker",
    "svp-keda",
    "svp-otelcol",
  ])

  # Key of each user's password in the External Secrets entries, the same name as the variable of the local .env:
  # svp-feed-service -> SVP_KAFKA_FEED_SERVICE_PASSWORD.
  password_keys = { for u in local.users : u => "SVP_KAFKA_${upper(replace(trimprefix(u, "svp-"), "-", "_"))}_PASSWORD" }

  # Topics are created without a replication factor and take the broker's. Apache Kafka keeps 3 for the internal topics
  # of consumer offsets and transactions, which MSK leaves at that value: with fewer brokers they could not be created,
  # so they follow the replication factor and minimum ISR of the env.
  server_properties = {
    "auto.create.topics.enable"                = "false"
    "allow.everyone.if.no.acl.found"           = "true"
    "default.replication.factor"               = tostring(var.replication_factor)
    "min.insync.replicas"                      = tostring(var.min_insync_replicas)
    "offsets.topic.replication.factor"         = tostring(var.replication_factor)
    "transaction.state.log.replication.factor" = tostring(var.replication_factor)
    "transaction.state.log.min.isr"            = tostring(var.min_insync_replicas)
    # MSK defaults this to true: a replica out of the ISR could become leader and drop writes acked with acks=all.
    "unclean.leader.election.enable" = "false"
  }

  log_group_name = "/aws/msk/${var.name}"
}

################################################################################
# Network
################################################################################

# Reachable on 9096 (SASL/SCRAM over TLS) from the given security groups only: no other port of MSK is open, so no
# client can fall back to plaintext (9092), TLS without a user (9094) or IAM (9098). No egress rule: the broker
# interfaces in these subnets only answer clients, and Terraform removes the allow-all egress rule AWS puts on a new
# group.
resource "aws_security_group" "this" {
  name_prefix = "${var.name}-kafka-"
  description = "MSK ${var.name}, 9096 from the cluster only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-kafka"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "scram" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.this.id
  description                  = "Kafka SASL/SCRAM from ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 9096
  to_port                      = 9096
  referenced_security_group_id = each.value
}

################################################################################
# Encryption key
################################################################################

# MSK refuses a SCRAM secret encrypted with the AWS managed key of Secrets Manager: it needs a customer managed
# symmetric key, given to the secret by key ARN rather than alias. The same key encrypts the broker volumes, so the env
# pays for one key. The default key policy: who may use the key is decided by IAM of the account.
resource "aws_kms_key" "this" {
  description              = "MSK ${var.name}: SCRAM secrets and broker storage"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 7
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-msk-scram"
  target_key_id = aws_kms_key.this.key_id
}

################################################################################
# Cluster
################################################################################

# A change of server_properties is a new revision of the same configuration, which MSK rolls out to the brokers one at
# a time. A new Kafka version line needs a new configuration: the name carries the version, so the new one exists
# before the cluster switches to it and the old one, then unused, can go.
resource "aws_msk_configuration" "this" {
  name           = "${var.name}-${replace(var.kafka_version, ".", "-")}"
  description    = "Brokers of ${var.name}: no topic auto-creation, replication of the env, ACLs enforced once any exists"
  kafka_versions = [var.kafka_version]

  # allow.everyone.if.no.acl.found=true is the MSK default and cannot be avoided: MSK has no super.users setting, so
  # with false no user could create the first ACL. The init job grants svp-admin ALL on the cluster and on every topic,
  # group and transactional id before any other ACL; from then on every resource has an ACL, and every other user gets
  # only what is granted to it.
  server_properties = join("\n", [for k in sort(keys(local.server_properties)) : "${k}=${local.server_properties[k]}"])

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_msk_cluster" "this" {
  cluster_name           = var.name
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.broker_count

  broker_node_group_info {
    instance_type   = var.broker_instance_type
    client_subnets  = var.subnet_ids
    security_groups = [aws_security_group.this.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.broker_volume_size
      }
    }
  }

  # SASL/SCRAM only: no unauthenticated access, no IAM (Kafka ACLs do not apply to IAM identities), no mutual TLS.
  client_authentication {
    unauthenticated = false

    sasl {
      scram = true
      iam   = false
    }
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = aws_kms_key.this.arn

    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = var.broker_logs_enabled
        log_group = var.broker_logs_enabled ? aws_cloudwatch_log_group.this[0].name : null
      }
    }
  }

  tags = {
    Name = var.name
  }
}

# MSK writes to an existing log group only; made here, it keeps the retention below and goes away with destroy.
resource "aws_cloudwatch_log_group" "this" {
  count = var.broker_logs_enabled ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.broker_logs_retention_days
}

################################################################################
# SCRAM users
################################################################################

# Letters and digits only, 32 characters: the password goes unescaped into a JAAS password="...". Ephemeral: opened on
# every plan and apply, never stored, and written only when password_version changes; every write below takes the value
# of the same opening. The random provider, not GetRandomPassword: the mocked AWS provider of terraform test cannot
# open that ephemeral resource.
ephemeral "random_password" "this" {
  for_each = local.users

  length  = 32
  special = false
}

# MSK reads a user from a secret named AmazonMSK_*, encrypted with a customer managed key, holding username and
# password. Deleted at once on destroy: the next session makes the env again with the same names.
resource "aws_secretsmanager_secret" "scram" {
  for_each = local.users

  name                    = "AmazonMSK_${var.name}-${each.key}"
  description             = "SCRAM user ${each.key} of MSK cluster ${var.name}"
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = 0
}

# Write-only: the value is in neither the plan nor the state.
resource "aws_secretsmanager_secret_version" "scram" {
  for_each = local.users

  secret_id = aws_secretsmanager_secret.scram[each.key].id
  secret_string_wo = jsonencode({
    username = each.key
    password = ephemeral.random_password.this[each.key].result
  })
  secret_string_wo_version = var.password_version
}

# One resource for every user: it owns the whole list of secrets of the cluster, and removes any secret it does not
# name, so a second association resource would undo this one.
resource "aws_msk_scram_secret_association" "this" {
  cluster_arn     = aws_msk_cluster.this.arn
  secret_arn_list = [for u in sort(tolist(local.users)) : aws_secretsmanager_secret.scram[u].arn]

  # MSK refuses to associate a secret without a value.
  depends_on = [aws_secretsmanager_secret_version.scram]
}

################################################################################
# External Secrets entries
################################################################################

# The same passwords, from the same ephemeral opening and with the same version, into the entries the cluster's
# External Secrets read: a client always gets the password its SCRAM secret holds. kafka-users holds every user but
# svp-admin, so all passwords change together (one password_version): rotating one user alone would write new values
# for the others into this entry without writing their SCRAM secrets.
resource "aws_secretsmanager_secret_version" "kafka_admin" {
  secret_id = var.kafka_admin_secret_id
  secret_string_wo = jsonencode({
    (local.password_keys["svp-admin"]) = ephemeral.random_password.this["svp-admin"].result
  })
  secret_string_wo_version = var.password_version
}

resource "aws_secretsmanager_secret_version" "kafka_users" {
  secret_id = var.kafka_users_secret_id
  secret_string_wo = jsonencode({
    for u in local.users : local.password_keys[u] => ephemeral.random_password.this[u].result if u != "svp-admin"
  })
  secret_string_wo_version = var.password_version
}
