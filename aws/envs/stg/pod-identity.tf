# AWS roles of the two services that use S3, assumed through EKS Pod Identity: one role per ServiceAccount of the svp
# namespace, each with the policy the media module writes for it. The platform controllers get theirs in modules/eks.
locals {
  service_roles = {
    video-service = module.media.video_service_policy_json
    media-worker  = module.media.media_worker_policy_json
  }
  # Namespace of the services; each service runs under a ServiceAccount named after its release.
  service_namespace = "svp"
}

# The trust policy names the cluster, namespace and ServiceAccount through the session tags EKS Pod Identity sets, so
# an association of another cluster or another ServiceAccount cannot use the role even if someone creates one.
data "aws_iam_policy_document" "service_trust" {
  for_each = local.service_roles

  statement {
    sid     = "AllowEksAuthToAssumeRoleForPodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-name"
      values   = [module.eks.cluster_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.service_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.key]
    }
  }
}

resource "aws_iam_role" "service" {
  for_each = local.service_roles

  name               = "${local.name}-${each.key}"
  description        = "${each.key} of EKS cluster ${local.name} (S3 of the ${local.env} buckets)"
  assume_role_policy = data.aws_iam_policy_document.service_trust[each.key].json
}

# Inline: the policy names the buckets of this env and belongs to this role alone.
resource "aws_iam_role_policy" "service" {
  for_each = local.service_roles

  name   = "s3"
  role   = aws_iam_role.service[each.key].id
  policy = each.value
}

resource "aws_eks_pod_identity_association" "service" {
  for_each = local.service_roles

  cluster_name    = module.eks.cluster_name
  namespace       = local.service_namespace
  service_account = each.key
  role_arn        = aws_iam_role.service[each.key].arn
}
