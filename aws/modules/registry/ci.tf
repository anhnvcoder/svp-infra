# IAM trusts GitHub's OIDC endpoint through its library of root CAs, so the provider needs no thumbprint.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # Push a release and its referrers, read them back to verify. Nothing on KMS: ECR uses the key through its grants.
  ecr_push_actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
    "ecr:InitiateLayerUpload",
    "ecr:UploadLayerPart",
    "ecr:CompleteLayerUpload",
    "ecr:PutImage",
    "ecr:DescribeImages",
  ]
}

# One exact sub claim per role: a job of another repository, branch or environment gets no credential.
data "aws_iam_policy_document" "ci_trust" {
  for_each = var.ci_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = [each.value.subject]
    }
  }
}

data "aws_iam_policy_document" "ci" {
  for_each = var.ci_roles

  # The API takes no resource.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "PushReleases"
    actions   = local.ecr_push_actions
    resources = [for r in each.value.repositories : "${local.repository_arn_prefix}/${r}"]
  }

  dynamic "statement" {
    for_each = each.value.delete ? [1] : []

    content {
      sid       = "DeleteReferrers"
      actions   = ["ecr:BatchDeleteImage"]
      resources = [for r in each.value.repositories : "${local.repository_arn_prefix}/${r}"]
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each = var.ci_roles

  name                 = each.key
  description          = "GitHub Actions ${each.value.subject}: copies releases into the ECR of svp-${var.env}"
  assume_role_policy   = data.aws_iam_policy_document.ci_trust[each.key].json
  max_session_duration = 3600

  # IAM refuses a trust policy whose principal does not exist yet; the ARN is built from the name, so say the order.
  depends_on = [aws_iam_openid_connect_provider.github]
}

resource "aws_iam_role_policy" "ci" {
  for_each = var.ci_roles

  name   = "ecr-push"
  role   = aws_iam_role.ci[each.key].id
  policy = data.aws_iam_policy_document.ci[each.key].json
}
