# Validation rules of the module's variables: one plan with valid values, then one plan per rule with a value that only
# that rule rejects. The AWS provider is a mock: nothing reaches an account; the module reads no data source.

mock_provider "aws" {}

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
