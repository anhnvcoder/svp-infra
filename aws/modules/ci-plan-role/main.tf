data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# Design notes: aws/modules/ci-plan-role/README.md.
locals {
  # The key policy of the state key (account-baseline module) names this role by its ARN: rename both together.
  role_name = "svp-ci-terraform-plan"

  partition   = data.aws_partition.current.partition
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region
  s3_service  = "s3.${local.region}.amazonaws.com"
  oidc_host   = "token.actions.githubusercontent.com"
  state_arn   = "arn:${local.partition}:s3:::${var.state_bucket}"
  media_arn   = "arn:${local.partition}:s3:::svp-${var.env}-media-${local.account_id}-${local.region}"
  state_reads = ["${local.state_arn}/aws/accounts/${var.env}/terraform.tfstate", "${local.state_arn}/aws/${var.env}/terraform.tfstate"]

  # Reads of workload data that ReadOnlyAccess allows or a resource policy could; no refresh of the planned roots
  # calls them. sqs:ReceiveMessage is not even a pure read: it hides the message from the consumer for a while.
  workload_data_actions = [
    "secretsmanager:GetSecretValue",
    "secretsmanager:BatchGetSecretValue",
    "dynamodb:GetItem",
    "dynamodb:BatchGetItem",
    "dynamodb:Query",
    "dynamodb:Scan",
    "dynamodb:PartiQLSelect",
    "dynamodb:GetRecords",
    "logs:GetLogEvents",
    "logs:FilterLogEvents",
    "logs:StartQuery",
    "logs:GetQueryResults",
    "logs:StartLiveTail",
    "logs:GetLogRecord",
    "logs:GetLogObject",
    "sqs:ReceiveMessage",
    "kinesis:GetRecords",
    "xray:BatchGetTraces",
    "xray:GetTraceSummaries",
    "aps:QueryMetrics",
    "aps:GetSeries",
    "aps:GetLabels",
    "aps:GetMetricMetadata",
    "rds:DownloadDBLogFilePortion",
    "rds:DownloadCompleteDBLogFile",
    "ec2:GetConsoleOutput",
    "ec2:GetConsoleScreenshot",
    "ec2:GetPasswordData",
  ]
}

# One exact sub claim, an environment whose reviewer approves each run: no other job, branch or fork gets in.
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [var.subject]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = local.role_name
  description          = "GitHub Actions ${var.subject}: terraform plan of the roots of svp-${var.env}, read only"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "read_only" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "read" {
  # ReadOnlyAccess has no kms:Decrypt, and the key policy of the state key delegates this role's use to IAM.
  statement {
    sid       = "StateKeyViaS3"
    actions   = ["kms:Decrypt"]
    resources = [var.state_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.s3_service]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [local.state_arn]
    }
  }

  # Refresh of aws_grafana_workspace_service_account and aws_pricingplanmanager_subscription calls them, and
  # ReadOnlyAccess lacks both. Neither API takes a resource ARN narrower than the account.
  statement {
    sid       = "RefreshReadsMissing"
    actions   = ["grafana:ListWorkspaceServiceAccounts", "pricingplanmanager:GetSubscription"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "read" {
  name   = "${local.role_name}-read"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.read.json
}

# An explicit Deny wins over ReadOnlyAccess and over any resource policy that opens more.
data "aws_iam_policy_document" "deny" {
  statement {
    sid       = "DenyWorkloadData"
    effect    = "Deny"
    actions   = local.workload_data_actions
    resources = ["*"]
  }

  # The probe object is public through CloudFront, and the refresh of aws_s3_object reads it with HeadObject.
  statement {
    sid           = "DenyObjectReads"
    effect        = "Deny"
    actions       = ["s3:GetObject*"]
    not_resources = concat(local.state_reads, ["${local.media_arn}/media/uptime-probe.txt"])
  }

  # SecureString parameters decrypt with KMS too, so this also keeps their values out of reach.
  statement {
    sid           = "DenyDecryptOtherKeys"
    effect        = "Deny"
    actions       = ["kms:Decrypt"]
    not_resources = [var.state_kms_key_arn]
  }

  statement {
    sid       = "DenyDecryptStateOutsideS3"
    effect    = "Deny"
    actions   = ["kms:Decrypt"]
    resources = [var.state_kms_key_arn]

    condition {
      test     = "StringNotEquals"
      variable = "kms:ViaService"
      values   = [local.s3_service]
    }
  }

  # Plan runs with -lock=false: the role never writes the state or its .tflock lock file.
  statement {
    sid         = "DenyStateWrites"
    effect      = "Deny"
    not_actions = ["s3:Get*", "s3:List*"]
    resources   = [local.state_arn, "${local.state_arn}/*"]
  }
}

resource "aws_iam_role_policy" "deny" {
  name   = "${local.role_name}-deny"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.deny.json
}
