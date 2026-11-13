# Only the entries; the learner writes the upstream tokens (keys username, accessToken). ECR takes no customer managed
# key for these secrets, so they use the AWS managed key of Secrets Manager.
resource "aws_secretsmanager_secret" "cache" {
  for_each = local.cache_credentials

  name        = "ecr-pullthroughcache/${each.key}"
  description = "Login of the ECR pull through cache rule ${each.key} to ${local.cache_rules[each.key].upstream}"
}

resource "aws_ecr_pull_through_cache_rule" "this" {
  for_each = local.cache_rules

  ecr_repository_prefix = each.key
  upstream_registry_url = each.value.upstream
  credential_arn        = each.value.credential ? aws_secretsmanager_secret.cache[each.key].arn : null
}

# Cached repositories expire images nobody pulled for 30 days: the upstream keeps the original.
locals {
  cache_lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire cached images not pulled for 30 days"
      selection = {
        tagStatus   = "any"
        countType   = "sinceImagePulled"
        countUnit   = "days"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

# Tags stay mutable: an immutable tag would stop ECR from updating a cached tag to its new upstream image.
resource "aws_ecr_repository_creation_template" "cache" {
  for_each = local.cache_rules

  prefix               = each.key
  description          = "Repositories the pull through cache rule ${each.key} creates"
  applied_for          = ["PULL_THROUGH_CACHE"]
  image_tag_mutability = "MUTABLE"
  lifecycle_policy     = local.cache_lifecycle_policy
  custom_role_arn      = aws_iam_role.template.arn

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
}

# ECR assumes this role to create a cached repository with the KMS key of the template.
data "aws_iam_policy_document" "template_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecr.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "template" {
  statement {
    sid       = "CreateCachedRepositories"
    actions   = ["ecr:CreateRepository", "ecr:TagResource"]
    resources = [for prefix in keys(local.cache_rules) : "${local.repository_arn_prefix}/${prefix}/*"]
  }

  statement {
    sid       = "EncryptWithEcrKey"
    actions   = ["kms:CreateGrant", "kms:RetireGrant", "kms:DescribeKey"]
    resources = [aws_kms_key.ecr.arn]
  }
}

resource "aws_iam_role" "template" {
  name               = "svp-${var.env}-ecr-template"
  description        = "Assumed by ECR to create the repositories of the pull through cache rules of svp-${var.env}"
  assume_role_policy = data.aws_iam_policy_document.template_trust.json
}

resource "aws_iam_role_policy" "template" {
  name   = "create-cached-repositories"
  role   = aws_iam_role.template.id
  policy = data.aws_iam_policy_document.template.json
}
