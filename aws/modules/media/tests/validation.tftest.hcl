# Validation rules of the module's variables: one plan with valid values, then one plan per rule with a value that only
# that rule rejects. The AWS provider is a mock: nothing reaches an account, and data sources return the values below
# (the provider still validates arguments, so policies must be JSON).

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }
}

variables {
  name_prefix          = "svp-stg"
  account_id           = "000000000000"
  region               = "ap-southeast-1"
  cors_allowed_origins = ["https://svp.example"]
  force_destroy        = true
}

run "valid" {
  command = plan
}

run "name_prefix_double_hyphen" {
  command = plan

  variables {
    name_prefix = "svp--stg"
  }

  expect_failures = [var.name_prefix]
}

run "account_id_short" {
  command = plan

  variables {
    account_id = "12345"
  }

  expect_failures = [var.account_id]
}

run "region_uppercase" {
  command = plan

  variables {
    region = "AP-SOUTHEAST-1"
  }

  expect_failures = [var.region]
}

run "cors_allowed_origins_with_path" {
  command = plan

  variables {
    cors_allowed_origins = ["https://svp.example/*"]
  }

  expect_failures = [var.cors_allowed_origins]
}

run "price_class_unknown" {
  command = plan

  variables {
    price_class = "PriceClass_300"
  }

  expect_failures = [var.price_class]
}
