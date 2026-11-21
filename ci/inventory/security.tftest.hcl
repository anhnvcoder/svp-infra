# Plan of aws/security on an empty security account, in the organization aws/org made: its five member accounts
# active, GuardDuty's detector already there (aws/org designates the delegated administrator).

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
      account_id = "000000000002"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_guardduty_detector" {
    defaults = {
      id = "00000000000000000000000000000000"
    }
  }
}

mock_provider "aws" {
  alias = "log_archive"

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
      account_id = "000000000001"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_kms_alias" {
    defaults = {
      target_key_arn = "arn:aws:kms:ap-southeast-1:000000000001:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "aws" {
  alias = "management"

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
      account_id = "000000000000"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_organizations_organization" {
    defaults = {
      id                   = "o-0000000000"
      master_account_id    = "000000000000"
      master_account_email = "mgmt@svp.example"
      roots                = [{ id = "r-0000" }]
      non_master_accounts = [
        { id = "000000000001", name = "svp-log-archive", state = "ACTIVE" },
        { id = "000000000002", name = "svp-security", state = "ACTIVE" },
        { id = "000000000003", name = "svp-backup", state = "ACTIVE" },
        { id = "000000000004", name = "svp-stg", state = "ACTIVE" },
        { id = "000000000005", name = "svp-prd", state = "ACTIVE" },
      ]
    }
  }
}

# Inspector turns itself on for ECR in the delegated administrator; the root imports that enabler (inspector.tf).
override_resource {
  target = aws_inspector2_enabler.security
}

variables {
  account_id             = "000000000000"
  security_account_id    = "000000000002"
  log_archive_account_id = "000000000001"
}

run "inventory" {
  command = plan
}
