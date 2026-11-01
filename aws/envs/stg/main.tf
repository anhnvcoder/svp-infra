locals {
  # Identity of this root. With the backend key of versions.tf, the only lines of code the prd root changes: sizes
  # and protections differ in <env>.tfvars. Every name below starts with svp-<env>, so the roots of two envs in one
  # account never claim the same IAM role, bucket, cluster or DB instance.
  env  = "stg"
  name = "svp-${local.env}"
}

module "network" {
  source = "../../modules/network"

  name               = local.name
  cluster_name       = local.name
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  flow_log_enabled   = var.flow_log_enabled
}

# Findings of trivy on the cluster the module builds with the values of this root, each a deliberate choice:
# - AWS-0040: the public endpoint of the Kubernetes API is on, so the learner's machine reaches it without a VPN or a
#   bastion. It answers only the ranges of eks_public_access_cidrs (the module refuses any range shorter than /8, so
#   never 0.0.0.0/0), and the private endpoint stays on for nodes and pods.
# - AWS-0041: fires on any public range, a single /32 included; the ranges are the learner's own (an uncommitted
#   *.auto.tfvars), see AWS-0040 for what limits them.
#trivy:ignore:AWS-0040
#trivy:ignore:AWS-0041
module "eks" {
  source = "../../modules/eks"

  name                         = local.name
  kubernetes_version           = var.kubernetes_version
  vpc_id                       = module.network.vpc_id
  private_subnet_ids           = module.network.private_subnet_ids
  endpoint_public_access       = var.eks_endpoint_public_access
  endpoint_public_access_cidrs = var.eks_public_access_cidrs
  control_plane_log_types      = var.control_plane_log_types
  node_instance_types          = var.node_instance_types
  node_capacity_type           = var.node_capacity_type
  node_min_size                = var.node_min_size
  node_desired_size            = var.node_desired_size
  node_max_size                = var.node_max_size
  hosted_zone_id               = var.hosted_zone_id
}

module "rds" {
  source = "../../modules/rds"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids

  # Pods carry addresses of their node's network interfaces (VPC CNI), so they connect with the node security group.
  # The cluster security group EKS creates sits on the control plane's network interfaces, and EKS also gives it to
  # what it launches without a security group of its own (Fargate pods, nodes of a group with no launch template).
  # The node group here does not carry it: its launch template names the node security group.
  allowed_security_groups = {
    node    = module.eks.node_security_group_id
    cluster = module.eks.cluster_primary_security_group_id
  }

  instance_class           = var.rds_instance_class
  multi_az                 = var.rds_multi_az
  backup_retention_period  = var.rds_backup_retention_period
  delete_automated_backups = var.rds_delete_automated_backups
  deletion_protection      = var.rds_deletion_protection
  skip_final_snapshot      = var.rds_skip_final_snapshot
}

module "media" {
  source = "../../modules/media"

  name_prefix          = local.name
  account_id           = var.account_id
  region               = var.region
  cors_allowed_origins = ["https://${var.domain}"]
  force_destroy        = var.media_force_destroy
  price_class          = var.media_price_class
}

# Read to check that domain lies inside the lab zone: ExternalDNS and cert-manager may only write that zone, so a web
# name outside it would get neither a record nor a certificate.
data "aws_route53_zone" "lab" {
  zone_id = var.hosted_zone_id
}

# Address ranges of S3 in the region, as AWS publishes them. NetworkPolicies of the VPC CNI match addresses, not names,
# so the pods that call S3 are allowed exactly these ranges on 443. The list is read at every plan: a range AWS adds
# during a session is reachable only after the next apply.
data "aws_ip_ranges" "s3" {
  regions  = [var.region]
  services = ["s3"]
}
