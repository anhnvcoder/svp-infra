locals {
  # The ServiceAccounts of the platform controllers that get an AWS role. The charts that install them must use
  # these namespaces and names; the role trusts exactly this pair.
  pod_identity = {
    aws_load_balancer_controller = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
    external_dns = {
      namespace       = "external-dns"
      service_account = "external-dns"
    }
    cert_manager = {
      namespace       = "cert-manager"
      service_account = "cert-manager"
    }
    # Associated by the aws-ebs-csi-driver add-on itself (addons.tf).
    ebs_csi = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
  }
}

resource "aws_eks_pod_identity_association" "aws_load_balancer_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.pod_identity.aws_load_balancer_controller.namespace
  service_account = local.pod_identity.aws_load_balancer_controller.service_account
  role_arn        = aws_iam_role.aws_load_balancer_controller.arn
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.pod_identity.external_dns.namespace
  service_account = local.pod_identity.external_dns.service_account
  role_arn        = aws_iam_role.external_dns.arn
}

resource "aws_eks_pod_identity_association" "cert_manager" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.pod_identity.cert_manager.namespace
  service_account = local.pod_identity.cert_manager.service_account
  role_arn        = aws_iam_role.cert_manager.arn
}
