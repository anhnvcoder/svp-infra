# One ElastiCache for Valkey replication group per env, cluster mode off: clients speak plain (not cluster) Valkey
# over TLS and log in as one RBAC user each, limited to its own database and key prefix. Passwords are made and
# written in the same apply without passing through plan or state.
# Design notes: aws/modules/elasticache/README.md.

locals {
  # Access strings of the platform's users, the same text as the local aclfile. No default user: a user group of
  # engine VALKEY needs none, and ElastiCache turns the default user off once the group is attached.
  users = {
    "svp-gateway"      = "on ~svp:gw:* resetchannels db=10 -@all +select +client|setinfo +eval +evalsha +time +get +set +del"
    "svp-feed-service" = "on ~svp:feed:* resetchannels db=14 -@all +select +client|setinfo +get +set"
    "svp-web"          = "on ~svp:web:* resetchannels db=9 -@all +select +client|setinfo +eval +get +set +del +exists"
    "svp-ops"          = "on ~svp:* resetchannels db=9,10,14 -@all +select +ping +time +scan +get +mget +pttl (~svp:gw:rl:register:* resetchannels db=10 -@all +del) (~svp:feed:explore:* resetchannels db=14 -@all +del)"
  }

  # Key of each user's password in the External Secrets entry, the same name as the variable of the local .env:
  # svp-feed-service -> SVP_VALKEY_FEED_SERVICE_PASSWORD.
  password_keys = { for u in keys(local.users) : u => "SVP_VALKEY_${upper(replace(trimprefix(u, "svp-"), "-", "_"))}_PASSWORD" }

  # A user ID is unique in the account and region while user names repeat across groups, so the ID carries the env.
  user_ids = { for u in keys(local.users) : u => "${var.name}-${trimprefix(u, "svp-")}" }

  engine_major_version = split(".", var.engine_version)[0]

  # A replica only helps when it can take over: with two nodes or more the group fails over to it on its own
  # (Multi-AZ); one node has nothing to fail over to.
  replicated = var.node_count >= 2
}

################################################################################
# Network
################################################################################

resource "aws_elasticache_subnet_group" "this" {
  name        = var.name
  description = "Database subnets of ${var.name}"
  subnet_ids  = var.subnet_ids
}

# Reachable on 6379 from the given security groups only. No egress rule: the nodes open no connection themselves, and
# Terraform removes the allow-all egress rule AWS puts on a new group.
resource "aws_security_group" "this" {
  name_prefix = "${var.name}-valkey-"
  description = "Valkey ${var.name}, 6379 from the cluster only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-valkey"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "valkey" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.this.id
  description                  = "Valkey from ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = each.value
}

################################################################################
# Replication group
################################################################################

# noeviction: the keys are rate limit counters, sessions and caches the services expect to find again; a full memory
# must fail writes loudly rather than drop a session or a counter in silence (the default is volatile-lru).
resource "aws_elasticache_parameter_group" "this" {
  name        = "${var.name}-valkey${local.engine_major_version}"
  description = "Valkey ${local.engine_major_version} of ${var.name}, no eviction"
  family      = "valkey${local.engine_major_version}"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }

  # A new major means a new family, hence a new group, which must exist before the replication group switches to it.
  lifecycle {
    create_before_destroy = true
  }
}

# The data is disposable (rate limits, sessions, caches rebuilt from the services): no automatic or final snapshot.
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "Valkey of ${var.name}"

  engine               = "valkey"
  engine_version       = var.engine_version
  node_type            = var.node_type
  num_cache_clusters   = var.node_count
  cluster_mode         = "disabled"
  parameter_group_name = aws_elasticache_parameter_group.this.name
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  automatic_failover_enabled = local.replicated
  multi_az_enabled           = local.replicated

  # RBAC users need TLS; required refuses any plaintext connection, so a client without rediss:// fails at connect.
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  at_rest_encryption_enabled = true
  user_group_ids             = [aws_elasticache_user_group.this.user_group_id]

  snapshot_retention_limit = 0

  # An env lives for one session: a change waiting for the maintenance window would never be seen.
  apply_immediately = true

  tags = {
    Name = var.name
  }
}

################################################################################
# Users
################################################################################

# Letters and digits only, 32 characters: the password goes unescaped into a REDIS_URL and a Valkey aclfile line.
# Ephemeral: opened on every plan and apply, never stored, and written only when password_version changes; every write
# below takes the value of the same opening. The random provider, not GetRandomPassword: the mocked AWS provider of
# terraform test cannot open that ephemeral resource.
ephemeral "random_password" "this" {
  for_each = local.users

  length  = 32
  special = false
}

# Changing an access string or a password updates the user in place: the user group and the replication group stay.
resource "aws_elasticache_user" "this" {
  for_each = local.users

  user_id       = local.user_ids[each.key]
  user_name     = each.key
  engine        = "valkey"
  access_string = each.value

  passwords_wo         = ephemeral.random_password.this[each.key].result
  passwords_wo_version = var.password_version
}

resource "aws_elasticache_user_group" "this" {
  user_group_id = var.name
  engine        = "valkey"
  user_ids      = [for u in sort(keys(local.users)) : aws_elasticache_user.this[u].user_id]
}

################################################################################
# External Secrets entry
################################################################################

# The same passwords, from the same ephemeral opening and version, into the entry the cluster's External Secrets read:
# after a complete apply a client gets the password its ElastiCache user holds. One entry for every user, so all
# passwords change together (one password_version).
resource "aws_secretsmanager_secret_version" "valkey_users" {
  secret_id = var.valkey_users_secret_id
  secret_string_wo = jsonencode({
    for u in keys(local.users) : local.password_keys[u] => ephemeral.random_password.this[u].result
  })
  secret_string_wo_version = var.password_version
}
