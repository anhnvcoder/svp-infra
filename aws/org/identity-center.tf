# The organization instance of IAM Identity Center, owned by the management account. Its existing permission sets
# (those of the management account itself) are not managed here.
data "aws_ssoadmin_instances" "this" {
  provider = aws.sso

  lifecycle {
    postcondition {
      condition     = length(self.arns) == 1
      error_message = "Expected exactly one IAM Identity Center instance in sso_region; check sso_region against the SSO profile."
    }
  }
}

locals {
  sso_instance_arn  = one(data.aws_ssoadmin_instances.this.arns)
  identity_store_id = one(data.aws_ssoadmin_instances.this.identity_store_ids)
}

data "aws_identitystore_user" "learner" {
  provider = aws.sso

  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = var.sso_user_name
    }
  }
}

data "aws_partition" "current" {}

resource "aws_ssoadmin_permission_set" "admin" {
  provider = aws.sso

  name         = "SvpAdmin"
  description  = "Administrator of the svp member accounts"
  instance_arn = local.sso_instance_arn
  # An hour of administrator rights at a time. A long apply is not cut: with an sso-session profile the SDK takes new
  # role credentials from the SSO token while the access portal session lasts. Design notes: README.md.
  session_duration = "PT1H"
}

resource "aws_ssoadmin_managed_policy_attachment" "admin" {
  provider = aws.sso

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  managed_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

# Assigning the permission set provisions it into the account; the policy is attached first so the role IAM Identity
# Center creates there (AWSReservedSSO_SvpAdmin_...) carries it from the start.
resource "aws_ssoadmin_account_assignment" "learner" {
  provider = aws.sso
  for_each = local.member_envs

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  principal_id       = data.aws_identitystore_user.learner.user_id
  principal_type     = "USER"
  target_id          = aws_organizations_account.member[each.key].id
  target_type        = "AWS_ACCOUNT"

  depends_on = [aws_ssoadmin_managed_policy_attachment.admin]
}

# Reading configuration, state and the findings of the detection services, without the data: ViewOnlyAccess and
# SecurityAudit grant neither S3 objects nor secret values nor table rows. Assigned where the daily runbooks read.
resource "aws_ssoadmin_permission_set" "read_only" {
  provider = aws.sso

  name             = "SvpReadOnly"
  description      = "Read-only access to configuration and security findings, no data"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "read_only" {
  provider = aws.sso
  for_each = toset(["job-function/ViewOnlyAccess", "SecurityAudit"])

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.read_only.arn
  managed_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.key}"
}

# The log reads of an investigation (EKS control plane, RDS); none of these actions writes.
data "aws_iam_policy_document" "read_only" {
  statement {
    sid    = "ReadLogEvents"
    effect = "Allow"
    actions = [
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
      "logs:GetQueryResults",
      "logs:StartQuery",
      "logs:StopQuery",
    ]
    resources = ["*"]
  }
}

resource "aws_ssoadmin_permission_set_inline_policy" "read_only" {
  provider = aws.sso

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.read_only.arn
  inline_policy      = data.aws_iam_policy_document.read_only.json
}

resource "aws_ssoadmin_account_assignment" "read_only" {
  provider = aws.sso
  for_each = {
    stg      = aws_organizations_account.member["stg"].id
    prd      = aws_organizations_account.member["prd"].id
    security = aws_organizations_account.security.id
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.read_only.arn
  principal_id       = data.aws_identitystore_user.learner.user_id
  principal_type     = "USER"
  target_id          = each.value
  target_type        = "AWS_ACCOUNT"

  depends_on = [
    aws_ssoadmin_managed_policy_attachment.read_only,
    aws_ssoadmin_permission_set_inline_policy.read_only,
  ]
}

locals {
  log_archive_id = aws_organizations_account.log_archive.id

  # The buckets of aws/log-archive, named <prefix>-<log archive account>-<region> like that root.
  log_bucket_arns = [
    for name in [
      "svp-cloudtrail-${local.log_archive_id}-${var.region}",
      "svp-cloudtrail-access-${local.log_archive_id}-${var.region}",
      "svp-config-${local.log_archive_id}-${var.region}",
      "svp-flowlogs-${local.log_archive_id}-${var.region}",
      "svp-guardduty-${local.log_archive_id}-${var.region}",
      "aws-waf-logs-svp-${local.log_archive_id}-us-east-1",
    ] : "arn:${data.aws_partition.current.partition}:s3:::${name}"
  ]
}

# Reading the logs of the log archive and nothing else there.
resource "aws_ssoadmin_permission_set" "log_reader" {
  provider = aws.sso

  name             = "SvpLogReader"
  description      = "Read the organization logs in the log archive account"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "log_reader" {
  provider = aws.sso

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.log_reader.arn
  managed_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/job-function/ViewOnlyAccess"
}

# The log keys share one alias in two regions; decrypting is allowed only on them and only when S3 asks, so the
# permission set reads log objects and cannot use the keys any other way.
data "aws_iam_policy_document" "log_reader" {
  statement {
    sid       = "ListLogBuckets"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = local.log_bucket_arns
  }

  statement {
    sid       = "ReadLogObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [for arn in local.log_bucket_arns : "${arn}/*"]
  }

  statement {
    sid       = "DecryptLogsThroughS3"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:${data.aws_partition.current.partition}:kms:*:${local.log_archive_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com", "s3.us-east-1.amazonaws.com"]
    }

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = ["alias/svp-log-archive"]
    }
  }
}

resource "aws_ssoadmin_permission_set_inline_policy" "log_reader" {
  provider = aws.sso

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.log_reader.arn
  inline_policy      = data.aws_iam_policy_document.log_reader.json
}

resource "aws_ssoadmin_account_assignment" "log_reader" {
  provider = aws.sso

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.log_reader.arn
  principal_id       = data.aws_identitystore_user.learner.user_id
  principal_type     = "USER"
  target_id          = local.log_archive_id
  target_type        = "AWS_ACCOUNT"

  depends_on = [
    aws_ssoadmin_managed_policy_attachment.log_reader,
    aws_ssoadmin_permission_set_inline_policy.log_reader,
  ]
}
