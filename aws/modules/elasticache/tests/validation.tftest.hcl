# The protections of the cache with the values of stg and of prd, then the validation rules of the module's variables.
# The AWS provider is a mock: nothing reaches an account (the provider still validates arguments, so ARNs must be well
# formed). Plans only, so attributes the provider computes stay unknown: the assertions read what the module sets.

mock_provider "aws" {}

variables {
  name                    = "svp-stg"
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_ids              = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  allowed_security_groups = { node = "sg-0123456789abcdef0", cluster = "sg-0fedcba9876543210" }
  node_count              = 1
  valkey_users_secret_id  = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp/stg/valkey-users-AbCdEf"
}

# Values of the stg root: one cache.t4g.micro node, no replica, no failover.
run "stg_values" {
  command = plan

  assert {
    condition     = aws_elasticache_replication_group.this.engine == "valkey" && aws_elasticache_replication_group.this.engine_version == "9.1" && aws_elasticache_replication_group.this.cluster_mode == "disabled"
    error_message = "The cache must run Valkey 9.1 with cluster mode off."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.transit_encryption_enabled == true && aws_elasticache_replication_group.this.transit_encryption_mode == "required"
    error_message = "The cache must refuse every connection without TLS."
  }

  assert {
    condition     = tostring(aws_elasticache_replication_group.this.at_rest_encryption_enabled) == "true"
    error_message = "The cache must encrypt its data at rest."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.auth_token == null && length(aws_elasticache_replication_group.this.user_group_ids) == 1
    error_message = "Clients must log in as RBAC users of the user group, never with an AUTH token."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.snapshot_retention_limit == 0 && aws_elasticache_replication_group.this.final_snapshot_identifier == null
    error_message = "The cache must take no automatic and no final snapshot."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.node_type == "cache.t4g.micro" && aws_elasticache_replication_group.this.num_cache_clusters == 1
    error_message = "stg must run one cache.t4g.micro node."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.automatic_failover_enabled == false && aws_elasticache_replication_group.this.multi_az_enabled == false
    error_message = "One node has no replica to fail over to: failover and Multi-AZ must be off."
  }

  assert {
    condition     = aws_elasticache_parameter_group.this.family == "valkey9" && one([for p in aws_elasticache_parameter_group.this.parameter : p.value if p.name == "maxmemory-policy"]) == "noeviction"
    error_message = "The parameter group must be of family valkey9 and evict no key."
  }

  # The default user is not in the group: ElastiCache turns it off for a group of engine VALKEY.
  assert {
    condition     = aws_elasticache_user_group.this.engine == "valkey" && toset(aws_elasticache_user_group.this.user_ids) == toset(["svp-stg-gateway", "svp-stg-feed-service", "svp-stg-web", "svp-stg-ops"])
    error_message = "The user group must hold the four platform users and no default user."
  }

  assert {
    condition     = alltrue([for u in aws_elasticache_user.this : u.user_name != "default" && u.engine == "valkey" && u.passwords_wo_version == 1])
    error_message = "Every user must be a Valkey user with a password of version 1, and none may be the default user."
  }

  assert {
    condition = { for u, user in aws_elasticache_user.this : u => user.access_string } == {
      "svp-gateway"      = "on ~svp:gw:* resetchannels db=10 -@all +select +client|setinfo +eval +evalsha +time +get +set +del"
      "svp-feed-service" = "on ~svp:feed:* resetchannels db=14 -@all +select +client|setinfo +get +set"
      "svp-web"          = "on ~svp:web:* resetchannels db=9 -@all +select +client|setinfo +eval +get +set +del +exists"
      "svp-ops"          = "on ~svp:* resetchannels db=9,10,14 -@all +select +ping +time +scan +get +mget +pttl (~svp:gw:rl:register:* resetchannels db=10 -@all +del) (~svp:feed:explore:* resetchannels db=14 -@all +del)"
    }
    error_message = "The access string of every user, the selectors of svp-ops included, must be the one of the local aclfile."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.valkey_users.secret_id == var.valkey_users_secret_id && aws_secretsmanager_secret_version.valkey_users.secret_string_wo_version == 1
    error_message = "The passwords must be written into the entry valkey-users given to the module, with the version of the users."
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.valkey)) == toset(["node", "cluster"]) && alltrue([for r in aws_vpc_security_group_ingress_rule.valkey : r.ip_protocol == "tcp" && r.from_port == 6379 && r.to_port == 6379 && r.cidr_ipv4 == null])
    error_message = "The security group must open TCP 6379 only, from the given security groups only."
  }
}

# Values of the prd root: a primary and a replica of cache.m7g.large, Multi-AZ with automatic failover.
run "prd_values" {
  command = plan

  variables {
    name                   = "svp-prd"
    subnet_ids             = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2", "subnet-0ccccccccccccccc3"]
    node_type              = "cache.m7g.large"
    node_count             = 2
    valkey_users_secret_id = "arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:svp/prd/valkey-users-AbCdEf"
    password_version       = 3
  }

  assert {
    condition     = aws_elasticache_replication_group.this.node_type == "cache.m7g.large" && aws_elasticache_replication_group.this.num_cache_clusters == 2
    error_message = "prd must run a primary and a replica of cache.m7g.large."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.automatic_failover_enabled == true && aws_elasticache_replication_group.this.multi_az_enabled == true
    error_message = "prd must run Multi-AZ with automatic failover."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.transit_encryption_enabled == true && aws_elasticache_replication_group.this.transit_encryption_mode == "required" && tostring(aws_elasticache_replication_group.this.at_rest_encryption_enabled) == "true"
    error_message = "prd must encrypt in transit, TLS required, and at rest."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.auth_token == null && aws_elasticache_replication_group.this.snapshot_retention_limit == 0
    error_message = "prd must use RBAC users only and take no snapshot."
  }

  assert {
    condition     = toset(aws_elasticache_user_group.this.user_ids) == toset(["svp-prd-gateway", "svp-prd-feed-service", "svp-prd-web", "svp-prd-ops"]) && alltrue([for u in aws_elasticache_user.this : u.user_name != "default"])
    error_message = "The users of prd must carry the env in their ID, and none may be the default user."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.valkey_users.secret_id == var.valkey_users_secret_id
    error_message = "The passwords of prd must be written into the entry valkey-users of prd."
  }

  # A version other than the default: the users and the entry take the one given, not a fixed number.
  assert {
    condition     = alltrue([for u in aws_elasticache_user.this : u.passwords_wo_version == 3]) && aws_secretsmanager_secret_version.valkey_users.secret_string_wo_version == 3
    error_message = "The users and the entry valkey-users must be written with the password version given to the module."
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

# 7.1 is a Redis OSS version, not a Valkey one.
run "engine_version_redis" {
  command = plan

  variables {
    engine_version = "7.1"
  }

  expect_failures = [var.engine_version]
}

# Valkey 9.0 has no db= in its ACL: a user could select any database.
run "engine_version_without_db_acl" {
  command = plan

  variables {
    engine_version = "9.0"
  }

  expect_failures = [var.engine_version]
}

run "engine_version_patch" {
  command = plan

  variables {
    engine_version = "9.1.3"
  }

  expect_failures = [var.engine_version]
}

run "node_type_not_elasticache" {
  command = plan

  variables {
    node_type = "t4g.micro"
  }

  expect_failures = [var.node_type]
}

run "node_count_zero" {
  command = plan

  variables {
    node_count = 0
  }

  expect_failures = [var.node_count]
}

run "node_count_above_six" {
  command = plan

  variables {
    node_count = 7
  }

  expect_failures = [var.node_count]
}

run "password_version_zero" {
  command = plan

  variables {
    password_version = 0
  }

  expect_failures = [var.password_version]
}
