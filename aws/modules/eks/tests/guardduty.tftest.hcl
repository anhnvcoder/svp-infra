# The GuardDuty Runtime Monitoring agent add-on: its configuration must give the agent a PriorityClass that preempts,
# so a node already full of pods still gets one. The AWS provider is a mock: nothing reaches an account, and data
# sources return the values below; configuration_values is a plain string a plan knows.

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
  name                 = "svp-stg"
  kubernetes_version   = "1.36"
  vpc_id               = "vpc-0123456789abcdef0"
  private_subnet_ids   = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  system_node_max_size = 4

  guardduty_data_endpoint_id = "vpce-0123456789abcdef0"

  amp_workspace_arn = "arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-0123abcd-4567-89ef-0123-456789abcdef"
  log_group_arn     = "arn:aws:logs:ap-southeast-1:000000000000:log-group:/svp/stg/otel"
  release_repository_arns = [
    "arn:aws:ecr:ap-southeast-1:000000000000:repository/svp-backend/gateway",
    "arn:aws:ecr:ap-southeast-1:000000000000:repository/svp-frontend/web",
  ]
  ecr_cache_prefixes = ["ghcr", "docker-hub", "quay", "k8s", "ecr-public"]
}

run "agent_preempts_on_full_nodes" {
  command = plan

  assert {
    condition = jsondecode(aws_eks_addon.guardduty_agent.configuration_values) == {
      priorityClassName = "aws-guardduty-agent.priorityclass-high"
    }
    error_message = "The agent add-on must set only priorityClassName: aws-guardduty-agent.priorityclass-high."
  }

  assert {
    condition     = aws_eks_addon.guardduty_agent.resolve_conflicts_on_update == "OVERWRITE"
    error_message = "A change to the GuardDuty agent's configuration must overwrite, not fail on, a conflicting field."
  }
}
