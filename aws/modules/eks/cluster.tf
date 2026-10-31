data "aws_partition" "current" {}

locals {
  # Provider default_tags do not reach what the node group's Auto Scaling group launches (instances, their volumes
  # and network interfaces get the tags of the launch template), so the tags session sweeps look for are passed in
  # here as well.
  tags = {
    Project = "svp"
  }
}

# Findings of trivy inside the registry module, each a deliberate choice:
# - AWS-0039: no customer managed key for Secrets; EKS encrypts the Kubernetes API data, Secrets included, with an
#   AWS owned key by default (see create_kms_key below).
# - AWS-0104: the node security group allows all egress. Nodes pull images from public registries through the NAT
#   gateway and pods call AWS APIs; egress per pod is narrowed by the NetworkPolicies of the charts.
#trivy:ignore:AWS-0039
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
  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access ? var.endpoint_public_access_cidrs : []

  # Access entries only (no aws-auth ConfigMap); the identity that runs apply gets cluster admin through an access
  # entry, so no ARN is written anywhere.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Pods get AWS credentials through EKS Pod Identity, which needs no OIDC provider.
  enable_irsa = false

  # No customer managed KMS key ($1 a month each, and it outlives the cluster for the deletion window): EKS encrypts
  # the Kubernetes API data, Secrets included, with an AWS owned key by default.
  create_kms_key    = false
  encryption_config = null

  enabled_log_types                      = var.control_plane_log_types
  create_cloudwatch_log_group            = length(var.control_plane_log_types) > 0
  cloudwatch_log_group_retention_in_days = var.control_plane_log_retention_days

  # A minor that leaves standard support is upgraded by EKS instead of moving to extended support, which bills the
  # control plane six times the hour.
  upgrade_policy = {
    support_type = "STANDARD"
  }

  node_security_group_enable_recommended_rules = local.node_security_group_enable_recommended_rules

  addons                  = local.addons
  eks_managed_node_groups = local.eks_managed_node_groups

  tags = local.tags
}
