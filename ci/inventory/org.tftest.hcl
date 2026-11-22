# Plan of aws/org on an empty management account: the organization, its accounts, the trail, Identity Center.
# Data sources get the values an organization with one Identity Center instance answers with.

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
}

mock_provider "aws" {
  alias = "sso"

  mock_data "aws_ssoadmin_instances" {
    defaults = {
      arns               = ["arn:aws:sso:::instance/ssoins-0000000000000000"]
      identity_store_ids = ["d-0000000000"]
    }
  }

  mock_data "aws_identitystore_user" {
    defaults = {
      user_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "aws" {
  alias = "log_archive"

  mock_data "aws_kms_alias" {
    defaults = {
      target_key_arn = "arn:aws:kms:ap-southeast-1:000000000001:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  account_id    = "000000000000"
  sso_user_name = "learner"
  security_contact = {
    name          = "Learner"
    title         = "Owner"
    email_address = "security-contact@svp.example"
    phone_number  = "+00 000 000 000"
  }
}

run "inventory" {
  command = plan
}
