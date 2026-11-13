# Validation rules of the module's variables: one plan with valid values, then one plan per rule with a value that only
# that rule rejects. The AWS provider is a mock: nothing reaches an account, and data sources return the values below
# (the provider still validates arguments, so policies must be JSON and ARNs well formed).

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

  amp_workspace_arn         = "arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-0123abcd-4567-89ef-0123-456789abcdef"
  log_group_arn             = "arn:aws:logs:ap-southeast-1:000000000000:log-group:/svp/stg/otel"
  observability_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/0123abcd-4567-89ef-0123-456789abcdef"
  ecr_kms_key_arn           = "arn:aws:kms:ap-southeast-1:000000000000:key/89abcdef-0123-4567-89ab-cdef01234567"
  release_repository_arns = [
    "arn:aws:ecr:ap-southeast-1:000000000000:repository/svp-backend/gateway",
    "arn:aws:ecr:ap-southeast-1:000000000000:repository/svp-frontend/web",
  ]
  ecr_cache_prefixes = ["ghcr", "docker-hub", "quay", "k8s", "ecr-public"]
}

run "valid" {
  command = plan

  variables {
    endpoint_public_access           = true
    endpoint_public_access_cidrs     = ["192.0.2.10/32"]
    control_plane_log_types          = ["api", "audit"]
    control_plane_log_retention_days = 7
  }
}

# The defaults keep what the module did before secrets_kms_encryption existed: no customer managed key, the public
# endpoint off, no control plane log group. The cluster, the key and the node group are made inside the registry
# module, whose outputs show none of them during a plan, so the runs below read the arguments this module passes it
# (local.guards, local.eks_managed_node_groups, local.addons, local.karpenter_discovery_tag).
run "defaults" {
  command = plan

  assert {
    condition     = local.guards.create_kms_key == false && local.guards.encryption_config == null && module.eks.kms_key_arn == null
    error_message = "By default the module must create no KMS key for Secrets."
  }

  assert {
    condition     = local.guards.endpoint_private_access == true && local.guards.endpoint_public_access == false && length(local.guards.endpoint_public_access_cidrs) == 0
    error_message = "By default the API must be reachable through its private endpoint only."
  }

  assert {
    condition     = module.eks.cloudwatch_log_group_name == null
    error_message = "By default the module must create no control plane log group."
  }

}

# Values of the stg root: two zones. The system node group, the Karpenter names and the pinned versions are the same
# in every env; only the number of zones and the maximum of the group change.
run "stg_values" {
  command = plan

  assert {
    condition     = length(local.eks_managed_node_groups) == 1 && contains(keys(local.eks_managed_node_groups), "system")
    error_message = "The module must make one managed node group, system, and no other."
  }

  assert {
    condition     = local.eks_managed_node_groups.system.capacity_type == "ON_DEMAND" && local.eks_managed_node_groups.system.instance_types == ["m7g.large"]
    error_message = "The system node group must run On-Demand m7g.large nodes, Spot never: Karpenter and Argo CD run there."
  }

  assert {
    condition     = local.eks_managed_node_groups.system.min_size == 2 && local.eks_managed_node_groups.system.desired_size == 2 && local.eks_managed_node_groups.system.max_size == 4
    error_message = "With two zones the system node group must start with two nodes, one per zone, and grow to system_node_max_size."
  }

  assert {
    condition     = local.eks_managed_node_groups.system.metadata_options.http_tokens == "required" && local.eks_managed_node_groups.system.metadata_options.http_put_response_hop_limit == 1
    error_message = "The system nodes must require IMDSv2 with a hop limit of 1, so containers cannot read the node's credentials."
  }

  assert {
    condition     = local.eks_managed_node_groups.system.block_device_mappings.root.ebs.volume_type == "gp3" && local.eks_managed_node_groups.system.block_device_mappings.root.ebs.volume_size == 30 && local.eks_managed_node_groups.system.block_device_mappings.root.ebs.encrypted
    error_message = "The root volume of the system nodes must be an encrypted gp3 of 30 GiB."
  }

  assert {
    condition     = local.eks_managed_node_groups.system.ami_type == "AL2023_ARM_64_STANDARD" && local.eks_managed_node_groups.system.ami_release_version == "1.36.5-20261107" && local.eks_managed_node_groups.system.use_latest_ami_release_version == false
    error_message = "The system node group must run the pinned AL2023 arm64 release, never the latest one at plan time."
  }

  assert {
    condition     = local.karpenter_discovery_tag == { "karpenter.sh/discovery" = "svp-stg" }
    error_message = "The node security group must carry karpenter.sh/discovery = <name> for the EC2NodeClass."
  }

  assert {
    condition     = output.karpenter_node_iam_role_name == "svp-stg-karpenter-node" && output.karpenter_queue_name == "svp-stg-karpenter" && module.karpenter.iam_role_name == "svp-stg-karpenter"
    error_message = "The Karpenter node role, interruption queue and controller role must be named svp-stg-karpenter-node, svp-stg-karpenter and svp-stg-karpenter, with no random suffix."
  }

  assert {
    condition     = !contains(keys(local.pod_identity), "karpenter")
    error_message = "Karpenter must get its Pod Identity association from the karpenter submodule only, not from local.pod_identity."
  }

  assert {
    condition = alltrue([for c in data.aws_iam_policy_document.karpenter_trust.statement[0].condition :
      c.test == "StringEquals" && toset(c.values) == toset(lookup({
        "aws:RequestTag/eks-cluster-name"           = ["svp-stg"]
        "aws:RequestTag/kubernetes-namespace"       = ["kube-system"]
        "aws:RequestTag/kubernetes-service-account" = ["karpenter"]
      }, c.variable, []))
    ]) && length(data.aws_iam_policy_document.karpenter_trust.statement[0].condition) == 3 && data.aws_iam_policy_document.karpenter_trust.statement[0].sid == "PodIdentity"
    error_message = "The Karpenter controller role must trust only this cluster, namespace kube-system and ServiceAccount karpenter, in the statement that replaces the one of the submodule (sid PodIdentity)."
  }

  assert {
    condition     = length(local.addons) == 6 && alltrue([for k, v in local.addons : can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", v.addon_version))])
    error_message = "Every EKS add-on must pin addon_version to a build such as v1.23.3-eksbuild.1."
  }

  # The GuardDuty agent is the seventh add-on, outside local.addons so that it can wait for the guardduty-data endpoint.
  assert {
    condition     = aws_eks_addon.guardduty_agent.addon_name == "aws-guardduty-agent" && aws_eks_addon.guardduty_agent.addon_version == "v1.17.3-eksbuild.2"
    error_message = "The GuardDuty agent add-on must pin addon_version, as every other add-on does."
  }
}

run "secrets_kms_encryption_on" {
  command = plan

  variables {
    secrets_kms_encryption = true
  }

  assert {
    condition     = local.guards.create_kms_key == true && local.guards.encryption_config.resources == ["secrets"]
    error_message = "secrets_kms_encryption = true must have the registry module create a key and envelope-encrypt Secrets with it."
  }
}

# Values of the prd root: public endpoint off with no range at all, the five control plane logs, Secrets under a key
# of the env, the system node group over three zones.
run "prd_values" {
  command = plan

  variables {
    name                             = "svp-prd"
    private_subnet_ids               = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2", "subnet-0ccccccccccccccc3"]
    endpoint_public_access           = false
    control_plane_log_types          = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
    control_plane_log_retention_days = 30
    secrets_kms_encryption           = true
    system_node_max_size             = 6
  }

  assert {
    condition     = local.guards.endpoint_private_access == true && local.guards.endpoint_public_access == false && length(local.guards.endpoint_public_access_cidrs) == 0
    error_message = "prd must reach the API through its private endpoint only, with no public range."
  }

  assert {
    condition     = local.guards.create_kms_key == true && local.guards.encryption_config.resources == ["secrets"]
    error_message = "prd must envelope-encrypt Secrets with a customer managed key of the env."
  }

  assert {
    condition     = module.eks.cloudwatch_log_group_name == "/aws/eks/svp-prd/cluster"
    error_message = "prd must send its control plane logs to the log group of the cluster."
  }

  assert {
    condition     = local.eks_managed_node_groups.system.capacity_type == "ON_DEMAND" && local.eks_managed_node_groups.system.min_size == 3 && local.eks_managed_node_groups.system.desired_size == 3 && local.eks_managed_node_groups.system.max_size == 6
    error_message = "prd must start the system node group with three On-Demand nodes, one per zone."
  }

  assert {
    condition     = local.eks_managed_node_groups.system.metadata_options.http_tokens == "required" && local.eks_managed_node_groups.system.metadata_options.http_put_response_hop_limit == 1
    error_message = "The system nodes of prd must require IMDSv2 with a hop limit of 1."
  }

  assert {
    condition     = local.karpenter_discovery_tag == { "karpenter.sh/discovery" = "svp-prd" }
    error_message = "The node security group of prd must carry karpenter.sh/discovery = svp-prd."
  }

  assert {
    condition     = output.karpenter_node_iam_role_name == "svp-prd-karpenter-node" && output.karpenter_queue_name == "svp-prd-karpenter" && module.karpenter.iam_role_name == "svp-prd-karpenter"
    error_message = "The Karpenter names of prd must be svp-prd-karpenter-node, svp-prd-karpenter and svp-prd-karpenter, with no random suffix."
  }

  assert {
    condition     = !contains(keys(local.pod_identity), "karpenter")
    error_message = "Karpenter must get its Pod Identity association from the karpenter submodule only."
  }

  assert {
    condition     = alltrue([for k, v in local.addons : can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", v.addon_version))])
    error_message = "Every EKS add-on of prd must pin addon_version."
  }
}

# No controller of the cluster writes DNS: the edge records live in Terraform, so no Pod Identity role reaches Route 53.
run "no_dns_writer" {
  command = plan

  assert {
    condition = toset(keys(local.pod_identity)) == toset([
      "aws_load_balancer_controller", "ebs_csi", "otel_collector", "prometheus_agent", "ack_prometheusservice", "kyverno_admission",
      "argo_rollouts",
    ])
    error_message = "Only the AWS Load Balancer Controller, the EBS CSI driver and the five roles of pod_identity_roles get a Pod Identity role from this module."
  }
}

# Each workload role trusts exactly its own namespace and ServiceAccount of this cluster; the expected pairs are written
# out here, not read from local.pod_identity, so a change of either side fails this run.
run "pod_identity_trust" {
  command = plan

  assert {
    condition = alltrue([for k, sa in {
      otel_collector        = ["svp-obs", "otel-collector"]
      prometheus_agent      = ["svp-obs", "kps-prometheus"]
      ack_prometheusservice = ["svp-obs", "ack-prometheusservice-controller"]
      kyverno_admission     = ["kyverno", "kyverno-admission-controller"]
      argo_rollouts         = ["argo-rollouts", "argo-rollouts"]
      } : length(data.aws_iam_policy_document.pod_identity_trust[k].statement[0].condition) == 3 && alltrue([
        for c in data.aws_iam_policy_document.pod_identity_trust[k].statement[0].condition :
        c.test == "StringEquals" && toset(c.values) == toset(lookup({
          "aws:RequestTag/eks-cluster-name"           = ["svp-stg"]
          "aws:RequestTag/kubernetes-namespace"       = [sa[0]]
          "aws:RequestTag/kubernetes-service-account" = [sa[1]]
        }, c.variable, []))
      ])
    ])
    error_message = "Each workload role must trust only this cluster and its namespace/ServiceAccount: svp-obs/otel-collector, svp-obs/kps-prometheus, svp-obs/ack-prometheusservice-controller, kyverno/kyverno-admission-controller, argo-rollouts/argo-rollouts."
  }

  assert {
    condition = alltrue([for k, sa in {
      otel_collector        = ["svp-obs", "otel-collector"]
      prometheus_agent      = ["svp-obs", "kps-prometheus"]
      ack_prometheusservice = ["svp-obs", "ack-prometheusservice-controller"]
      kyverno_admission     = ["kyverno", "kyverno-admission-controller"]
      argo_rollouts         = ["argo-rollouts", "argo-rollouts"]
      } : aws_eks_pod_identity_association.pod_identity[k].cluster_name == "svp-stg" && aws_eks_pod_identity_association.pod_identity[k].namespace == sa[0] && aws_eks_pod_identity_association.pod_identity[k].service_account == sa[1]
    ]) && length(aws_eks_pod_identity_association.pod_identity) == 5
    error_message = "Each workload role must have exactly one Pod Identity association, with the namespace and ServiceAccount its role trusts."
  }

  assert {
    condition = {
      for k, r in aws_iam_role.pod_identity : k => r.name
      } == {
      otel_collector        = "svp-stg-otel-collector"
      prometheus_agent      = "svp-stg-prometheus-agent"
      ack_prometheusservice = "svp-stg-ack-prometheusservice"
      kyverno_admission     = "svp-stg-kyverno-admission"
      argo_rollouts         = "svp-stg-argo-rollouts"
    }
    error_message = "The workload roles must be named <name>-otel-collector, -prometheus-agent, -ack-prometheusservice, -kyverno-admission and -argo-rollouts."
  }
}

# Each workload policy holds exactly these statements: sid, actions and resources, on the ARNs passed in.
run "pod_identity_permissions" {
  command = plan

  assert {
    condition = toset([for s in data.aws_iam_policy_document.otel_collector.statement : s.sid]) == toset(["WriteMetrics", "WriteLogs", "UseLogGroupKeyThroughLogs", "WriteSpans"]) && alltrue([
      for s in data.aws_iam_policy_document.otel_collector.statement :
      toset(s.actions) == toset(lookup({
        WriteMetrics              = ["aps:RemoteWrite"]
        WriteLogs                 = ["logs:PutLogEvents"]
        UseLogGroupKeyThroughLogs = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        WriteSpans                = ["xray:PutTraceSegments"]
        }, s.sid, [])) && toset(s.resources) == toset(lookup({
        WriteMetrics              = ["arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-0123abcd-4567-89ef-0123-456789abcdef"]
        WriteLogs                 = ["arn:aws:logs:ap-southeast-1:000000000000:log-group:/svp/stg/otel:log-stream:otel-collector"]
        UseLogGroupKeyThroughLogs = ["arn:aws:kms:ap-southeast-1:000000000000:key/0123abcd-4567-89ef-0123-456789abcdef"]
        WriteSpans                = ["*"]
      }, s.sid, []))
    ])
    error_message = "The Collector may only remote write to the workspace, put events into the stream otel-collector of the log group, use the observability key and put trace segments."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.otel_collector.statement : s.sid != "UseLogGroupKeyThroughLogs" || (
        length(s.condition) == 1 && alltrue([for c in s.condition : c.test == "StringEquals" && c.variable == "kms:ViaService" && toset(c.values) == toset(["logs.ap-southeast-1.amazonaws.com"])])
      )
    ])
    error_message = "The Collector may use the observability key only through CloudWatch Logs of the region (kms:ViaService)."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.prometheus_agent.statement) == 1 && toset(data.aws_iam_policy_document.prometheus_agent.statement[0].actions) == toset(["aps:RemoteWrite"]) && toset(data.aws_iam_policy_document.prometheus_agent.statement[0].resources) == toset(["arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-0123abcd-4567-89ef-0123-456789abcdef"])
    error_message = "The Prometheus agent may only remote write to the workspace."
  }

  assert {
    condition = toset([for s in data.aws_iam_policy_document.ack_prometheusservice.statement : s.sid]) == toset(["ManageRuleGroupsNamespaces", "ManageAlertManagerDefinition"]) && alltrue([
      for s in data.aws_iam_policy_document.ack_prometheusservice.statement :
      toset(s.actions) == toset(lookup({
        ManageRuleGroupsNamespaces = [
          "aps:CreateRuleGroupsNamespace", "aps:PutRuleGroupsNamespace", "aps:DescribeRuleGroupsNamespace", "aps:DeleteRuleGroupsNamespace",
          "aps:TagResource", "aps:UntagResource", "aps:ListTagsForResource",
        ]
        ManageAlertManagerDefinition = [
          "aps:CreateAlertManagerDefinition", "aps:PutAlertManagerDefinition", "aps:DescribeAlertManagerDefinition",
          "aps:DeleteAlertManagerDefinition", "aps:ListRuleGroupsNamespaces",
        ]
        }, s.sid, [])) && toset(s.resources) == toset(lookup({
        ManageRuleGroupsNamespaces   = ["arn:aws:aps:ap-southeast-1:000000000000:rulegroupsnamespace/ws-0123abcd-4567-89ef-0123-456789abcdef/*"]
        ManageAlertManagerDefinition = ["arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-0123abcd-4567-89ef-0123-456789abcdef"]
      }, s.sid, []))
    ])
    error_message = "The ACK controller may only manage the rule groups namespaces and the alert manager definition of the workspace."
  }

  assert {
    condition = toset([for s in data.aws_iam_policy_document.kyverno_admission.statement : s.sid]) == toset(["GetRegistryToken", "ReadReleaseImages"]) && alltrue([
      for s in data.aws_iam_policy_document.kyverno_admission.statement :
      toset(s.actions) == toset(lookup({
        GetRegistryToken  = ["ecr:GetAuthorizationToken"]
        ReadReleaseImages = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        }, s.sid, [])) && toset(s.resources) == toset(lookup({
        GetRegistryToken = ["*"]
        ReadReleaseImages = [
          "arn:aws:ecr:ap-southeast-1:000000000000:repository/svp-backend/gateway",
          "arn:aws:ecr:ap-southeast-1:000000000000:repository/svp-frontend/web",
        ]
      }, s.sid, []))
    ])
    error_message = "The Kyverno admission controller may only get a registry token and read images of the release repositories."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.argo_rollouts.statement) == 1 && toset(data.aws_iam_policy_document.argo_rollouts.statement[0].actions) == toset(["aps:QueryMetrics"]) && toset(data.aws_iam_policy_document.argo_rollouts.statement[0].resources) == toset(["arn:aws:aps:ap-southeast-1:000000000000:workspace/ws-0123abcd-4567-89ef-0123-456789abcdef"])
    error_message = "Argo Rollouts may only query metrics of the workspace."
  }

  # No wildcard action; resource * only for the actions that have no resource type.
  assert {
    condition = alltrue(flatten([
      for d in [
        data.aws_iam_policy_document.otel_collector, data.aws_iam_policy_document.prometheus_agent,
        data.aws_iam_policy_document.ack_prometheusservice, data.aws_iam_policy_document.kyverno_admission,
        data.aws_iam_policy_document.argo_rollouts, data.aws_iam_policy_document.node_ecr_cache,
        ] : [for s in d.statement : [
          for a in s.actions : a != "*" && !endswith(a, ":*") && (!contains(s.resources, "*") || contains(["ecr:GetAuthorizationToken", "xray:PutTraceSegments"], a))
      ]]
    ]))
    error_message = "No workload or node policy may grant a wildcard action, and resource * is only for ecr:GetAuthorizationToken and xray:PutTraceSegments."
  }

  assert {
    condition     = alltrue([for k, p in aws_iam_role_policy.pod_identity : p.name == aws_iam_role.pod_identity[k].name]) && toset(keys(aws_iam_role_policy.pod_identity)) == toset(keys(aws_iam_role.pod_identity))
    error_message = "Each workload role must carry its inline policy."
  }
}

# Nodes may import from upstream and create repositories only under the cache prefixes, never a release repository,
# and decrypt only with the registry key, only through ECR.
run "node_ecr_cache" {
  command = plan

  assert {
    condition = toset([for s in data.aws_iam_policy_document.node_ecr_cache.statement : s.sid]) == toset(["ImportThroughPullThroughCache", "DecryptImagesThroughEcr"]) && alltrue([
      for s in data.aws_iam_policy_document.node_ecr_cache.statement : s.sid != "ImportThroughPullThroughCache" || (
        toset(s.actions) == toset(["ecr:BatchImportUpstreamImage", "ecr:CreateRepository"]) && toset(s.resources) == toset([
          "arn:aws:ecr:ap-southeast-1:000000000000:repository/ghcr/*",
          "arn:aws:ecr:ap-southeast-1:000000000000:repository/docker-hub/*",
          "arn:aws:ecr:ap-southeast-1:000000000000:repository/quay/*",
          "arn:aws:ecr:ap-southeast-1:000000000000:repository/k8s/*",
          "arn:aws:ecr:ap-southeast-1:000000000000:repository/ecr-public/*",
        ])
      )
    ])
    error_message = "Nodes may only import upstream images and create repositories under repository/<cache prefix>/*."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.node_ecr_cache.statement : s.sid != "DecryptImagesThroughEcr" || (
        toset(s.actions) == toset(["kms:Decrypt"]) && toset(s.resources) == toset(["arn:aws:kms:ap-southeast-1:000000000000:key/89abcdef-0123-4567-89ab-cdef01234567"]) &&
        length(s.condition) == 1 && alltrue([for c in s.condition : c.test == "StringEquals" && c.variable == "kms:ViaService" && toset(c.values) == toset(["ecr.ap-southeast-1.amazonaws.com"])])
      )
    ])
    error_message = "Nodes may only decrypt with the registry key, and only through ECR of the region (kms:ViaService)."
  }

  assert {
    condition     = toset(keys(aws_iam_role_policy.node_ecr_cache)) == toset(["system", "karpenter"]) && aws_iam_role_policy.node_ecr_cache["karpenter"].role == "svp-stg-karpenter-node"
    error_message = "Both node roles, of the system node group and of the Karpenter nodes, must carry the pull through cache policy."
  }
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-stg"
  }

  expect_failures = [var.name]
}

run "kubernetes_version_patch" {
  command = plan

  variables {
    kubernetes_version = "1.36.0"
  }

  expect_failures = [var.kubernetes_version]
}

# A minor the pinned AMI release is not built for: the image and kubernetes_version move together.
run "kubernetes_version_not_ami_minor" {
  command = plan

  variables {
    kubernetes_version = "1.37"
  }

  expect_failures = [var.kubernetes_version]
}

run "vpc_id_malformed" {
  command = plan

  variables {
    vpc_id = "vpc_0123"
  }

  expect_failures = [var.vpc_id]
}

run "private_subnet_ids_one_zone" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
  }

  expect_failures = [var.private_subnet_ids]
}

run "endpoint_public_access_cidrs_not_cidr" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["not-a-cidr"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "endpoint_public_access_cidrs_whole_internet" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "endpoint_public_access_without_cidrs" {
  command = plan

  variables {
    endpoint_public_access       = true
    endpoint_public_access_cidrs = []
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "control_plane_log_types_unknown" {
  command = plan

  variables {
    control_plane_log_types = ["kubelet"]
  }

  expect_failures = [var.control_plane_log_types]
}

run "control_plane_log_retention_days_not_offered" {
  command = plan

  variables {
    control_plane_log_retention_days = 2
  }

  expect_failures = [var.control_plane_log_retention_days]
}

run "system_node_instance_type_not_graviton" {
  command = plan

  variables {
    system_node_instance_type = "m7i.large"
  }

  expect_failures = [var.system_node_instance_type]
}

# Fewer nodes than zones: the group starts with one node per zone.
run "system_node_max_size_below_zones" {
  command = plan

  variables {
    system_node_max_size = 1
  }

  expect_failures = [var.system_node_max_size]
}

run "system_node_max_size_fraction" {
  command = plan

  variables {
    system_node_max_size = 4.5
  }

  expect_failures = [var.system_node_max_size]
}

run "guardduty_data_endpoint_id_not_vpce" {
  command = plan

  variables {
    guardduty_data_endpoint_id = "vpc-0123456789abcdef0"
  }

  expect_failures = [var.guardduty_data_endpoint_id]
}

run "amp_workspace_arn_not_workspace" {
  command = plan

  variables {
    amp_workspace_arn = "arn:aws:aps:ap-southeast-1:000000000000:rulegroupsnamespace/ws-0123abcd/svp-alerts"
  }

  expect_failures = [var.amp_workspace_arn]
}

# The provider's log group ARN has no :* suffix; with one, the stream ARN of the Collector policy would be wrong.
run "log_group_arn_with_wildcard" {
  command = plan

  variables {
    log_group_arn = "arn:aws:logs:ap-southeast-1:000000000000:log-group:/svp/stg/otel:*"
  }

  expect_failures = [var.log_group_arn]
}

# A wildcard key would let the Collector use every key of the account through CloudWatch Logs.
run "observability_kms_key_arn_wildcard" {
  command = plan

  variables {
    observability_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/*"
  }

  expect_failures = [var.observability_kms_key_arn]
}

# A wildcard key would let nodes decrypt with every key of the account through ECR.
run "ecr_kms_key_arn_wildcard" {
  command = plan

  variables {
    ecr_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/*"
  }

  expect_failures = [var.ecr_kms_key_arn]
}

run "release_repository_arns_empty" {
  command = plan

  variables {
    release_repository_arns = []
  }

  expect_failures = [var.release_repository_arns]
}

run "release_repository_arns_wildcard" {
  command = plan

  variables {
    release_repository_arns = ["arn:aws:ecr:ap-southeast-1:000000000000:repository/*"]
  }

  expect_failures = [var.release_repository_arns]
}

run "ecr_cache_prefixes_empty" {
  command = plan

  variables {
    ecr_cache_prefixes = []
  }

  expect_failures = [var.ecr_cache_prefixes]
}

run "ecr_cache_prefixes_wildcard" {
  command = plan

  variables {
    ecr_cache_prefixes = ["ghcr/*"]
  }

  expect_failures = [var.ecr_cache_prefixes]
}
