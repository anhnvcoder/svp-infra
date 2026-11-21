# Plan of aws/backup on an empty backup account of the organization aws/org made.

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
  account_id        = "000000000000"
  backup_account_id = "000000000003"
  stg_account_id    = "000000000004"
  prd_account_id    = "000000000005"
}

run "inventory" {
  command = plan
}
