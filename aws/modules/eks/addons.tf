locals {
  # EKS managed add-ons. The module creates the cluster without the self-managed vpc-cni, CoreDNS and kube-proxy EKS
  # used to install, so each of them is here. Versions: the latest release of each add-on for kubernetes_version,
  # resolved at plan time (the plan shows it).
  addons = {
    # Before the node group, so the first nodes come up with pod networking and with the prefix delegation setting
    # that decides their pod limit.
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        # Network policy agent on every node: the NetworkPolicies of the charts are enforced as on k3d.
        enableNetworkPolicy = "true"
        env = {
          # /28 prefixes instead of single addresses on each network interface: a node of size large holds 110 pods
          # instead of 29.
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    # Before the node group, so a pod that relies on Pod Identity never starts on a node without the agent.
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {
      before_compute = true
    }
    coredns = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = local.pod_identity.ebs_csi.service_account
      }]
      configuration_values = jsonencode({
        controller = {
          # Volumes of PersistentVolumeClaims live outside the Terraform state; the tag lets the session sweep find a
          # volume left after destroy.
          extraVolumeTags = local.tags
        }
      })
    }
    # The resource metrics API (kubectl top, HorizontalPodAutoscaler on CPU), which k3s ships and EKS does not. The
    # API server reaches it on port 10251 of the node (see security-groups.tf).
    metrics-server = {}
  }
}
