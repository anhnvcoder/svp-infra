# Plan of aws/accounts/<env> on an empty env account (stg and prd share this file): baseline, registry and CI roles,
# observability, the backup vault. The values of aws/paid-features.json decide the resources a flag switches.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000004"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
    }
  }
}

variables {
  account_id        = "000000000004"
  backup_account_id = "000000000003"
}

run "inventory" {
  command = plan
}
