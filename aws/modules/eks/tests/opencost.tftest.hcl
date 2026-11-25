# The Pod Identity of OpenCost: its role, the association of its ServiceAccount and a policy that only reads the
# metrics of the workspace. The AWS provider is a mock: nothing reaches an account, and data sources return the values
# below; the policy statements are read from the data source's arguments, which a plan knows.

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

run "opencost_identity" {
  command = plan

  assert {
    condition     = aws_iam_role.pod_identity["opencost"].name == "svp-stg-opencost"
    error_message = "The OpenCost role must be named <name>-opencost."
  }

  assert {
    condition = (aws_eks_pod_identity_association.pod_identity["opencost"].cluster_name == "svp-stg" &&
      aws_eks_pod_identity_association.pod_identity["opencost"].namespace == "svp-obs" &&
    aws_eks_pod_identity_association.pod_identity["opencost"].service_account == "opencost")
    error_message = "OpenCost must have one Pod Identity association for svp-obs/opencost of this cluster."
  }

  assert {
    condition = length(data.aws_iam_policy_document.pod_identity_trust["opencost"].statement[0].condition) == 3 && alltrue([
      for c in data.aws_iam_policy_document.pod_identity_trust["opencost"].statement[0].condition :
      c.test == "StringEquals" && toset(c.values) == toset(lookup({
        "aws:RequestTag/eks-cluster-name"           = ["svp-stg"]
        "aws:RequestTag/kubernetes-namespace"       = ["svp-obs"]
        "aws:RequestTag/kubernetes-service-account" = ["opencost"]
      }, c.variable, []))
    ])
    error_message = "The OpenCost role must trust only svp-obs/opencost of this cluster."
  }

  assert {
    condition = (length(data.aws_iam_policy_document.opencost.statement) == 1 &&
      toset(data.aws_iam_policy_document.opencost.statement[0].actions) == toset([
        "aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata",
      ]) &&
      toset(data.aws_iam_policy_document.opencost.statement[0].resources) == toset([
        "arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-0123abcd-4567-89ef-0123-456789abcdef",
    ]))
    error_message = "OpenCost may only run the four read actions of AmazonPrometheusQueryAccess on the workspace: no price, EC2 or S3 permission, no wildcard."
  }

  assert {
    condition     = aws_iam_role_policy.pod_identity["opencost"].name == "svp-stg-opencost"
    error_message = "The OpenCost role must carry its inline policy."
  }
}
