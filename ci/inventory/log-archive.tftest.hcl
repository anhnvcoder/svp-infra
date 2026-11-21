# Plan of aws/log-archive on an empty log archive account of the organization aws/org made.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_organizations_organization" {
    defaults = {
      id                = "o-0000000000"
      master_account_id = "000000000000"
    }
  }
}

variables {
  account_id             = "000000000000"
  log_archive_account_id = "000000000001"
  security_account_id    = "000000000002"
  stg_account_id         = "000000000004"
  prd_account_id         = "000000000005"
}

run "inventory" {
  command = plan
}
