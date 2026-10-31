# One role per platform controller, assumed through EKS Pod Identity. The trust policy names the cluster, namespace
# and ServiceAccount through the session tags EKS Pod Identity sets, so an association of another cluster or of
# another ServiceAccount cannot use the role even if someone creates one.
data "aws_iam_policy_document" "pod_identity_trust" {
  for_each = local.pod_identity

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
      values   = [var.name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [each.value.namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account]
    }
  }
}

locals {
  hosted_zone_arn = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.hosted_zone_id}"
}

################################################################################
# AWS Load Balancer Controller
################################################################################

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${var.name}-aws-load-balancer-controller"
  description        = "AWS Load Balancer Controller of EKS cluster ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust["aws_load_balancer_controller"].json
}

# The policy the project publishes for this exact controller release (docs/install/iam_policy.json at tag v3.6.2),
# kept as it is. The chart version that installs the controller must match: upgrading the controller means replacing
# this file with the policy of the new tag in the same change.
resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "${var.name}-aws-load-balancer-controller"
  description = "IAM policy of AWS Load Balancer Controller v3.6.2 for EKS cluster ${var.name}"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-v3.6.2.json")
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

################################################################################
# ExternalDNS
################################################################################

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid       = "ChangeRecordsOfTheLabZone"
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets", "route53:ListTagsForResources"]
    resources = [local.hosted_zone_arn]
  }

  # Listing zones has no resource-level permission; ExternalDNS lists them, then keeps only the zone id it is given.
  statement {
    sid       = "ListZones"
    actions   = ["route53:ListHostedZones"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "${var.name}-external-dns"
  description        = "ExternalDNS of EKS cluster ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust["external_dns"].json
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "route53-lab-zone"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

################################################################################
# cert-manager (ACME DNS-01 through Route 53)
################################################################################

data "aws_iam_policy_document" "cert_manager" {
  statement {
    sid       = "WatchChanges"
    actions   = ["route53:GetChange"]
    resources = ["arn:${data.aws_partition.current.partition}:route53:::change/*"]
  }

  # DNS-01 writes and removes only the TXT records of _acme-challenge names, in the lab zone only.
  statement {
    sid       = "ChangeChallengeRecords"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [local.hosted_zone_arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }

    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["_acme-challenge.*"]
    }
  }

  statement {
    sid       = "ReadRecords"
    actions   = ["route53:ListResourceRecordSets"]
    resources = [local.hosted_zone_arn]
  }

  # Finding the zone of a name has no resource-level permission.
  statement {
    sid       = "FindZone"
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "cert_manager" {
  name               = "${var.name}-cert-manager"
  description        = "cert-manager of EKS cluster ${var.name} (ACME DNS-01)"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust["cert_manager"].json
}

resource "aws_iam_role_policy" "cert_manager" {
  name   = "route53-acme-dns01"
  role   = aws_iam_role.cert_manager.id
  policy = data.aws_iam_policy_document.cert_manager.json
}

################################################################################
# EBS CSI driver
################################################################################

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi-driver"
  description        = "EBS CSI driver controller of EKS cluster ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust["ebs_csi"].json
}

# The AWS managed policy of the driver: create, attach, resize and delete volumes and their snapshots, and tag them.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
