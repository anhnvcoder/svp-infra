# Validation rules of the module's variables: one plan with valid values, then one plan per rule with a value that only
# that rule rejects. The AWS provider is a mock: nothing reaches an account, and data sources return the values below
# (a mocked list is empty otherwise, and the module takes its zones from it).

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c", "ap-southeast-1d", "ap-southeast-1e", "ap-southeast-1f"]
    }
  }
}

variables {
  name         = "svp-stg"
  cluster_name = "svp-stg"
}

run "valid" {
  command = plan
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp"
  }

  expect_failures = [var.name]
}

run "cidr_too_small" {
  command = plan

  variables {
    cidr = "10.0.0.0/24"
  }

  expect_failures = [var.cidr]
}

run "az_count_one" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}

run "cluster_name_leading_dash" {
  command = plan

  variables {
    cluster_name = "-svp"
  }

  expect_failures = [var.cluster_name]
}

run "flow_log_retention_days_not_offered" {
  command = plan

  variables {
    flow_log_retention_days = 2
  }

  expect_failures = [var.flow_log_retention_days]
}
