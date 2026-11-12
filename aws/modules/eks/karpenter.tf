locals {
  # The ServiceAccount of the Karpenter chart. The submodule associates it with the controller role through Pod
  # Identity, so it stays out of local.pod_identity, whose roles this module associates itself.
  karpenter_service_account = {
    namespace       = "kube-system"
    service_account = "karpenter"
  }

  # Subnet and security group discovery of the EC2NodeClass; the private subnets carry the same tag (network module).
  karpenter_discovery_tag = { "karpenter.sh/discovery" = var.name }
}

# Same trust as the other controller roles (iam.tf): only this cluster, namespace and ServiceAccount. The statement
# replaces the one of the submodule, which has the same sid and trusts any Pod Identity association of the account.
data "aws_iam_policy_document" "karpenter_trust" {
  statement {
    sid     = "PodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-name"
      values   = [var.name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.karpenter_service_account.namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.karpenter_service_account.service_account]
    }
  }
}

# Controller role and its policy, node role and its access entry, interruption queue and the EventBridge rules that
# feed it. Names are exact, without the random suffix of a name prefix: the chart and the EC2NodeClass derive them
# from the cluster name.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.29.0"

  cluster_name = module.eks.cluster_name

  iam_role_name                             = "${var.name}-karpenter"
  iam_role_use_name_prefix                  = false
  iam_role_description                      = "Karpenter controller of EKS cluster ${var.name}"
  iam_role_override_assume_policy_documents = [data.aws_iam_policy_document.karpenter_trust.json]
  iam_policy_name                           = "${var.name}-karpenter"

  namespace       = local.karpenter_service_account.namespace
  service_account = local.karpenter_service_account.service_account

  node_iam_role_name            = "${var.name}-karpenter-node"
  node_iam_role_use_name_prefix = false
  node_iam_role_description     = "Nodes Karpenter launches for EKS cluster ${var.name}"

  queue_name = "${var.name}-karpenter"

  tags = local.tags
}
