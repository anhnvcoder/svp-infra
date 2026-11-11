locals {
  # One release of the EKS optimized AL2023 arm64 image for this node group and the EC2NodeClass of Karpenter, so
  # stg and prd run the same image. Bumped by hand with kubernetes_version (aws/modules/eks/README.md).
  ami_release_version = "1.36.5-20261107"

  eks_managed_node_groups = {
    # Runs what must be up before Karpenter has a node of its own (add-ons, Argo CD, Karpenter itself), so it stays
    # On-Demand and untainted; one node per zone, scaled by nothing but a person.
    system = {
      # Graviton nodes run the arm64 image, the architecture of the dev machine; release images are multi-arch.
      ami_type                       = "AL2023_ARM_64_STANDARD"
      ami_release_version            = local.ami_release_version
      use_latest_ami_release_version = false
      instance_types                 = [var.system_node_instance_type]
      capacity_type                  = "ON_DEMAND"

      min_size     = length(var.private_subnet_ids)
      desired_size = length(var.private_subnet_ids)
      max_size     = var.system_node_max_size

      # IMDSv2 only, with a hop limit of 1: a container (one network hop away from the instance) cannot read the
      # node's credentials from the instance metadata service. Pods that need AWS get their own role through Pod
      # Identity.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      # 30 GiB instead of the image's 20 GiB: the platform pulls some thirty images on every node.
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }
}
