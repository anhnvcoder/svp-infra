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
  hosted_zone_id       = "Z0123456789ABCDEFGHIJ"
  system_node_max_size = 4
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

# ExternalDNS writes only the record types it publishes, so the role of the zone that holds a child zone's delegation
# cannot change that NS record.
run "external_dns_record_types" {
  command = plan

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.external_dns.statement :
      !contains(s.actions, "route53:ChangeResourceRecordSets") || (
        length(s.actions) == 1 &&
        length(s.condition) == 1 &&
        one(s.condition).test == "ForAllValues:StringEquals" &&
        one(s.condition).variable == "route53:ChangeResourceRecordSetsRecordTypes" &&
        toset(one(s.condition).values) == toset(["A", "AAAA", "CNAME", "TXT"])
      )
    ])
    error_message = "ExternalDNS may change only A, AAAA, CNAME and TXT records (ForAllValues:StringEquals route53:ChangeResourceRecordSetsRecordTypes), never NS."
  }

  assert {
    condition = anytrue([for s in data.aws_iam_policy_document.external_dns.statement :
      contains(s.actions, "route53:ChangeResourceRecordSets") && toset(s.resources) == toset(["arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHIJ"])
    ])
    error_message = "ExternalDNS must be allowed to change records of the zone of the env only."
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

run "hosted_zone_id_lowercase" {
  command = plan

  variables {
    hosted_zone_id = "z0123456789abcdefghij"
  }

  expect_failures = [var.hosted_zone_id]
}
