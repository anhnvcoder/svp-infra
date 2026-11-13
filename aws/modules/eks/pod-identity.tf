locals {
  # The ServiceAccounts of the platform controllers that get an AWS role. The charts that install them must use
  # these namespaces and names; the role trusts exactly this pair.
  pod_identity = {
    aws_load_balancer_controller = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
    # Associated by the aws-ebs-csi-driver add-on itself (addons.tf).
    ebs_csi = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
    otel_collector = {
      namespace       = "svp-obs"
      service_account = "otel-collector"
    }
    # Both replicas of the agent run under this one ServiceAccount, so one association covers them.
    prometheus_agent = {
      namespace       = "svp-obs"
      service_account = "kps-prometheus"
    }
    ack_prometheusservice = {
      namespace       = "svp-obs"
      service_account = "ack-prometheusservice-controller"
    }
    kyverno_admission = {
      namespace       = "kyverno"
      service_account = "kyverno-admission-controller"
    }
    argo_rollouts = {
      namespace       = "argo-rollouts"
      service_account = "argo-rollouts"
    }
  }
}

resource "aws_eks_pod_identity_association" "aws_load_balancer_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.pod_identity.aws_load_balancer_controller.namespace
  service_account = local.pod_identity.aws_load_balancer_controller.service_account
  role_arn        = aws_iam_role.aws_load_balancer_controller.arn
}

resource "aws_eks_pod_identity_association" "pod_identity" {
  for_each = local.pod_identity_roles

  cluster_name    = module.eks.cluster_name
  namespace       = local.pod_identity[each.key].namespace
  service_account = local.pod_identity[each.key].service_account
  role_arn        = aws_iam_role.pod_identity[each.key].arn
}
