locals {
  eks_managed_node_groups = {
    default = {
      # Graviton nodes run the arm64 image, the architecture of the dev machine; release images are multi-arch.
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

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
