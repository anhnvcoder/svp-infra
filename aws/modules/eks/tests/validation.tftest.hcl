# Validation rules of the module's variables: one plan with valid values, then one plan per rule with a value that only
# that rule rejects. The AWS provider is a mock: nothing reaches an account, and data sources return the values below
# (the provider still validates arguments, so policies must be JSON and ARNs well formed).

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
      arn        = "arn:aws:iam::000000000000:user/test"
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::000000000000:role/test"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      vpc_id = "vpc-0123456789abcdef0"
    }
  }
}

variables {
  name               = "svp-stg"
  kubernetes_version = "1.36"
  vpc_id             = "vpc-0123456789abcdef0"
  private_subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  hosted_zone_id     = "Z0123456789ABCDEFGHIJ"
}

run "valid" {
  command = plan

  variables {
    endpoint_public_access           = true
    endpoint_public_access_cidrs     = ["192.0.2.10/32"]
    control_plane_log_types          = ["api", "audit"]
    control_plane_log_retention_days = 7
  }
}

# The defaults keep what the module did before secrets_kms_encryption existed: no customer managed key, the public
# endpoint off, no control plane log group, Spot nodes. The cluster and the key are made inside the registry module,
# whose outputs show neither during a plan, so the runs below read the arguments this module passes it
# (local.guards, local.eks_managed_node_groups).
run "defaults" {
  command = plan

  assert {
    condition     = local.guards.create_kms_key == false && local.guards.encryption_config == null && module.eks.kms_key_arn == null
    error_message = "By default the module must create no KMS key for Secrets."
  }

  assert {
    condition     = local.guards.endpoint_private_access == true && local.guards.endpoint_public_access == false && length(local.guards.endpoint_public_access_cidrs) == 0
    error_message = "By default the API must be reachable through its private endpoint only."
  }

  assert {
    condition     = module.eks.cloudwatch_log_group_name == null
    error_message = "By default the module must create no control plane log group."
  }

  assert {
    condition     = local.eks_managed_node_groups.default.capacity_type == "SPOT"
    error_message = "By default the nodes must stay Spot."
  }
}

run "secrets_kms_encryption_on" {
  command = plan

  variables {
    secrets_kms_encryption = true
  }

  assert {
    condition     = local.guards.create_kms_key == true && local.guards.encryption_config.resources == ["secrets"]
    error_message = "secrets_kms_encryption = true must have the registry module create a key and envelope-encrypt Secrets with it."
  }
}

# Values of the prd root: public endpoint off with no range at all, control plane logs, Secrets under a key of the
# env, On-Demand nodes over three zones.
run "prd_values" {
  command = plan

  variables {
    name                             = "svp-prd"
    private_subnet_ids               = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2", "subnet-0ccccccccccccccc3"]
    endpoint_public_access           = false
    control_plane_log_types          = ["api", "audit", "authenticator"]
    control_plane_log_retention_days = 30
    secrets_kms_encryption           = true
    node_instance_types              = ["m7g.large", "m6g.large"]
    node_capacity_type               = "ON_DEMAND"
    node_min_size                    = 3
    node_desired_size                = 3
    node_max_size                    = 6
  }

  assert {
    condition     = local.guards.endpoint_private_access == true && local.guards.endpoint_public_access == false && length(local.guards.endpoint_public_access_cidrs) == 0
    error_message = "prd must reach the API through its private endpoint only, with no public range."
  }

  assert {
    condition     = local.guards.create_kms_key == true && local.guards.encryption_config.resources == ["secrets"]
    error_message = "prd must envelope-encrypt Secrets with a customer managed key of the env."
  }

  assert {
    condition     = module.eks.cloudwatch_log_group_name == "/aws/eks/svp-prd/cluster"
    error_message = "prd must send its control plane logs to the log group of the cluster."
  }

  assert {
    condition     = local.eks_managed_node_groups.default.capacity_type == "ON_DEMAND" && local.eks_managed_node_groups.default.min_size == 3 && local.eks_managed_node_groups.default.desired_size == 3 && local.eks_managed_node_groups.default.max_size == 6
    error_message = "prd must run at least three On-Demand nodes."
  }
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-stg"
  }

  expect_failures = [var.name]
}

run "kubernetes_version_patch" {
  command = plan

  variables {
    kubernetes_version = "1.36.0"
  }

  expect_failures = [var.kubernetes_version]
}

run "vpc_id_malformed" {
  command = plan

  variables {
    vpc_id = "vpc_0123"
  }

  expect_failures = [var.vpc_id]
}

run "private_subnet_ids_one_zone" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
  }

  expect_failures = [var.private_subnet_ids]
}

run "endpoint_public_access_cidrs_not_cidr" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["not-a-cidr"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "endpoint_public_access_cidrs_whole_internet" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "endpoint_public_access_without_cidrs" {
  command = plan

  variables {
    endpoint_public_access       = true
    endpoint_public_access_cidrs = []
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "control_plane_log_types_unknown" {
  command = plan

  variables {
    control_plane_log_types = ["kubelet"]
  }

  expect_failures = [var.control_plane_log_types]
}

run "control_plane_log_retention_days_not_offered" {
  command = plan

  variables {
    control_plane_log_retention_days = 2
  }

  expect_failures = [var.control_plane_log_retention_days]
}

run "node_instance_types_not_graviton" {
  command = plan

  variables {
    node_instance_types = ["m7i.large"]
  }

  expect_failures = [var.node_instance_types]
}

run "node_capacity_type_lowercase" {
  command = plan

  variables {
    node_capacity_type = "spot"
  }

  expect_failures = [var.node_capacity_type]
}

run "node_min_size_zero" {
  command = plan

  variables {
    node_min_size = 0
  }

  expect_failures = [var.node_min_size]
}

run "node_desired_size_above_max" {
  command = plan

  variables {
    node_desired_size = 6
  }

  expect_failures = [var.node_desired_size]
}

# 5.5 breaks only the whole-number part: a maximum below node_min_size would fail node_desired_size as well.
run "node_max_size_fraction" {
  command = plan

  variables {
    node_max_size = 5.5
  }

  expect_failures = [var.node_max_size]
}

run "hosted_zone_id_lowercase" {
  command = plan

  variables {
    hosted_zone_id = "z0123456789abcdefghij"
  }

  expect_failures = [var.hosted_zone_id]
}
