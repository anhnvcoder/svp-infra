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
