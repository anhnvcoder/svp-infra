data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  # Provider default_tags do not reach what the node group's Auto Scaling group launches (instances, their volumes
  # and network interfaces get the tags of the launch template), so the tags session sweeps look for are passed in
  # here as well.
  tags = {
    Project = "svp"
  }

  # Arguments of the module call below that guard the API and Secrets. The cluster and its key are made inside the
  # registry module, whose outputs show none of them during a plan, so they are set here, where the tests read them.
  guards = {
    endpoint_private_access      = true
    endpoint_public_access       = var.endpoint_public_access
    endpoint_public_access_cidrs = var.endpoint_public_access ? var.endpoint_public_access_cidrs : []
    create_kms_key               = var.secrets_kms_encryption
    encryption_config            = var.secrets_kms_encryption ? { resources = ["secrets"] } : null
  }
}

# Design notes: aws/modules/eks/README.md.

# AWS-0039: no customer managed key for Secrets while secrets_kms_encryption is false; EKS then encrypts the Kubernetes
# API data, Secrets included, with an AWS owned key. Holds only for create_kms_key=false. The root of an env that keeps
# the key off repeats the exception, without condition, on its call of this module.
# Scope: stg only; prd: secrets_kms_encryption = true (customer managed KMS key; reading Secrets needs kms:Decrypt).

# AWS-0104: the node security group allows all egress. Nodes pull images from public registries through the NAT
# gateway and pods call AWS APIs; egress per pod is narrowed by the NetworkPolicies of the charts.
# Scope: every environment.
#trivy:ignore:AWS-0039[create_kms_key=false]
#trivy:ignore:AWS-0104
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # The private endpoint stays on: with the public endpoint limited to a few addresses, nodes in private subnets would
  # otherwise reach the API through the NAT gateway's address, which is not on the list, and never join.
  endpoint_private_access      = local.guards.endpoint_private_access
  endpoint_public_access       = local.guards.endpoint_public_access
  endpoint_public_access_cidrs = local.guards.endpoint_public_access_cidrs

  # Access entries only (no aws-auth ConfigMap); the identity that runs apply gets cluster admin through an access
  # entry, so no ARN is written anywhere.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Pods get AWS credentials through EKS Pod Identity, which needs no OIDC provider.
  enable_irsa = false

  # Off: no customer managed KMS key ($1 a month each, and it outlives the cluster for the deletion window); EKS
  # encrypts the Kubernetes API data, Secrets included, with an AWS owned key. On: the registry module creates a key
  # with its default key policy (the account, the identity that runs apply as administrator, the cluster role as
  # user) and envelope-encrypts Secrets with it.

  # The shortest deletion window AWS allows, 7 days, and an alias that starts with the cluster name, so the session
  # sweep tells a key pending deletion of this env apart.
  create_kms_key                  = local.guards.create_kms_key
  encryption_config               = local.guards.encryption_config
  kms_key_deletion_window_in_days = 7
  kms_key_aliases                 = ["${var.name}-eks-secrets"]

  enabled_log_types                      = var.control_plane_log_types
  create_cloudwatch_log_group            = length(var.control_plane_log_types) > 0
  cloudwatch_log_group_retention_in_days = var.control_plane_log_retention_days

  # A minor that leaves standard support is upgraded by EKS instead of moving to extended support, which bills the
  # control plane six times the hour.
  upgrade_policy = {
    support_type = "STANDARD"
  }

  node_security_group_enable_recommended_rules = local.node_security_group_enable_recommended_rules
  node_security_group_tags                     = local.karpenter_discovery_tag

  addons                  = local.addons
  eks_managed_node_groups = local.eks_managed_node_groups

  tags = local.tags
}
