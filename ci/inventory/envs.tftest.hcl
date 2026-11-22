# Plan of aws/envs/<env> (stg and prd share this file) on an env account where aws/accounts/<env> has applied: the
# data sources answer with what that root made (the AMP workspace of each env, the release repositories of ECR, the
# cache rules, the keys), and the region with three zones.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
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
      arn        = "arn:aws:sts::000000000004:assumed-role/learner/svp"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
      zone_ids = ["apse1-az1", "apse1-az2", "apse1-az3"]
    }
  }

  mock_data "aws_prometheus_workspaces" {
    defaults = {
      aliases       = ["svp-stg", "svp-prd"]
      workspace_ids = ["ws-00000000-0000-0000-0000-000000000001", "ws-00000000-0000-0000-0000-000000000002"]
    }
  }

  mock_data "aws_ecr_repositories" {
    defaults = {
      names = [
        "svp-backend/gateway", "svp-backend/user-service", "svp-backend/video-service", "svp-backend/engagement-service",
        "svp-backend/feed-service", "svp-backend/media-worker", "svp-backend/dlq-replay", "svp-frontend/web",
      ]
    }
  }

  mock_data "aws_ip_ranges" {
    defaults = {
      cidr_blocks = ["198.51.100.0/24", "203.0.113.0/24"]
    }
  }

  mock_data "aws_kms_alias" {
    defaults = {
      target_key_arn = "arn:aws:kms:ap-southeast-1:000000000004:key/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_data "aws_prometheus_workspace" {
    defaults = {
      arn                 = "arn:aws:aps:ap-southeast-1:000000000004:workspace/ws-00000000-0000-0000-0000-000000000001"
      prometheus_endpoint = "https://aps-workspaces.ap-southeast-1.amazonaws.com/workspaces/ws-00000000-0000-0000-0000-000000000001/"
    }
  }

  mock_data "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:ap-southeast-1:000000000004:log-group:/svp/env/otel"
    }
  }

  mock_data "aws_ecr_repository" {
    defaults = {
      arn = "arn:aws:ecr:ap-southeast-1:000000000004:repository/svp-backend/gateway"
    }
  }

  mock_data "aws_vpc_endpoint_service" {
    defaults = {
      availability_zones            = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
      vpc_endpoint_policy_supported = true
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::000000000004:role/learner"
    }
  }

  mock_data "aws_route53_zone" {
    defaults = {
      name = "svp.example."
    }
  }
}

mock_provider "aws" {
  alias = "us_east_1"

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
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
}

mock_provider "cloudinit" {}
mock_provider "null" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  account_id             = "000000000004"
  log_archive_account_id = "000000000001"
  backup_account_id      = "000000000003"
  media_signing_public_keys = {
    a = "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"
  }
}

run "inventory" {
  command = plan
}
