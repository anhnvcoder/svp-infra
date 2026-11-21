# What the plan role of an env guarantees: its trust, its session, the policies it holds and the Deny that keeps it off
# workload data and off writes to the state; then one plan per validation rule with a value only that rule rejects. The
# AWS provider is a mock: nothing reaches an account. Policies are asserted through the arguments of their
# aws_iam_policy_document data sources. Design notes: docs/handbook/14-ci.md.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
      arn        = "arn:aws:iam::111111111111:user/test"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }
}

variables {
  env               = "stg"
  oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  subject           = "repo:anhnvcoder@1000001/svp-infra@2000003:environment:terraform-plan"
  state_bucket      = "svp-tfstate-111111111111-ap-southeast-1"
  state_kms_key_arn = "arn:aws:kms:ap-southeast-1:111111111111:key/00000000-0000-0000-0000-000000000000"

  state_arn = "arn:aws:s3:::svp-tfstate-111111111111-ap-southeast-1"

  workload_data_actions = [
    "secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue", "dynamodb:GetItem", "dynamodb:BatchGetItem",
    "dynamodb:Query", "dynamodb:Scan", "dynamodb:PartiQLSelect", "dynamodb:GetRecords", "logs:GetLogEvents",
    "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults", "logs:StartLiveTail", "logs:GetLogRecord",
    "logs:GetLogObject", "sqs:ReceiveMessage", "kinesis:GetRecords", "xray:BatchGetTraces", "xray:GetTraceSummaries",
    "aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata", "rds:DownloadDBLogFilePortion",
    "rds:DownloadCompleteDBLogFile", "ec2:GetConsoleOutput", "ec2:GetConsoleScreenshot", "ec2:GetPasswordData",
  ]
}

run "stg" {
  command = plan

  # Role and trust: one name, one-hour sessions, the GitHub OIDC provider only, aud and exactly one sub.
  assert {
    condition     = aws_iam_role.this.name == "svp-ci-terraform-plan" && aws_iam_role.this.max_session_duration == 3600
    error_message = "The role must be svp-ci-terraform-plan with sessions of one hour."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.trust.statement) == 1 &&
      toset(one(data.aws_iam_policy_document.trust.statement).actions) == toset(["sts:AssumeRoleWithWebIdentity"]) &&
      one(one(data.aws_iam_policy_document.trust.statement).principals).type == "Federated" &&
      toset(one(one(data.aws_iam_policy_document.trust.statement).principals).identifiers) == toset([var.oidc_provider_arn]) &&
      toset([for c in one(data.aws_iam_policy_document.trust.statement).condition : jsonencode([c.test, c.variable, c.values])]) == toset([
        jsonencode(["StringEquals", "token.actions.githubusercontent.com:aud", ["sts.amazonaws.com"]]),
        jsonencode(["StringEquals", "token.actions.githubusercontent.com:sub", [var.subject]]),
      ])
    )
    error_message = "The role must trust the GitHub OIDC provider only, with StringEquals on aud sts.amazonaws.com and on exactly its one sub."
  }

  # Policies: ReadOnlyAccess, the read policy and the deny policy, nothing else.
  assert {
    condition     = aws_iam_role_policy_attachment.read_only.role == "svp-ci-terraform-plan" && aws_iam_role_policy_attachment.read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "The role must have the AWS managed policy ReadOnlyAccess attached."
  }

  assert {
    condition     = aws_iam_role_policy.read.name == "svp-ci-terraform-plan-read" && aws_iam_role_policy.deny.name == "svp-ci-terraform-plan-deny"
    error_message = "The role must hold the inline policies svp-ci-terraform-plan-read and svp-ci-terraform-plan-deny."
  }

  # Read policy: kms:Decrypt on the state key only through S3 on the state bucket, and the two reads refresh lacks.
  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.read.statement : (
      s.sid == "StateKeyViaS3" ? (
        toset(s.actions) == toset(["kms:Decrypt"]) && toset(s.resources) == toset([var.state_kms_key_arn]) &&
        toset([for c in s.condition : jsonencode([c.test, c.variable, c.values])]) == toset([
          jsonencode(["StringEquals", "kms:ViaService", ["s3.ap-southeast-1.amazonaws.com"]]),
          jsonencode(["StringEquals", "kms:EncryptionContext:aws:s3:arn", [var.state_arn]]),
        ])
      ) :
      s.sid == "RefreshReadsMissing" && length(s.condition) == 0 &&
      toset(s.actions) == toset(["grafana:ListWorkspaceServiceAccounts", "pricingplanmanager:GetSubscription"])
    )]) && length(data.aws_iam_policy_document.read.statement) == 2 && toset([for s in data.aws_iam_policy_document.read.statement : s.sid]) == toset(["StateKeyViaS3", "RefreshReadsMissing"])
    error_message = "The read policy must hold exactly StateKeyViaS3 (kms:Decrypt on the state key through S3 on the state bucket) and RefreshReadsMissing."
  }

  # Deny policy: five statements, every one a Deny.
  assert {
    condition = toset([for s in data.aws_iam_policy_document.deny.statement : s.sid]) == toset([
      "DenyWorkloadData", "DenyObjectReads", "DenyDecryptOtherKeys", "DenyDecryptStateOutsideS3", "DenyStateWrites",
    ]) && alltrue([for s in data.aws_iam_policy_document.deny.statement : s.effect == "Deny"]) && length(data.aws_iam_policy_document.deny.statement) == 5
    error_message = "The deny policy must hold exactly the five Deny statements of the role."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.deny.statement :
      toset(s.actions) == toset(var.workload_data_actions) && toset(s.resources) == toset(["*"]) && length(s.condition) == 0
      if s.sid == "DenyWorkloadData"
    ])
    error_message = "DenyWorkloadData must deny every read of workload data (secret values, items, log events, messages, traces) on every resource."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.deny.statement :
      toset(s.actions) == toset(["s3:GetObject*"]) && s.resources == null && toset(s.not_resources) == toset([
        "${var.state_arn}/aws/accounts/stg/terraform.tfstate",
        "${var.state_arn}/aws/stg/terraform.tfstate",
        "arn:aws:s3:::svp-stg-media-111111111111-ap-southeast-1/media/uptime-probe.txt",
      ])
      if s.sid == "DenyObjectReads"
    ])
    error_message = "DenyObjectReads must deny every object read but the two state keys of the env and the uptime probe object."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.deny.statement : (
      s.sid == "DenyDecryptOtherKeys" ? toset(s.actions) == toset(["kms:Decrypt"]) && toset(s.not_resources) == toset([var.state_kms_key_arn]) && length(s.condition) == 0 :
      s.sid == "DenyDecryptStateOutsideS3" ? toset(s.actions) == toset(["kms:Decrypt"]) && toset(s.resources) == toset([var.state_kms_key_arn]) &&
      toset([for c in s.condition : jsonencode([c.test, c.variable, c.values])]) == toset([
        jsonencode(["StringNotEquals", "kms:ViaService", ["s3.ap-southeast-1.amazonaws.com"]]),
      ]) :
      true
    )])
    error_message = "kms:Decrypt must be denied on every key but the state key, and on the state key outside S3."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.deny.statement :
      s.actions == null && toset(s.not_actions) == toset(["s3:Get*", "s3:List*"]) &&
      toset(s.resources) == toset([var.state_arn, "${var.state_arn}/*"]) && length(s.condition) == 0
      if s.sid == "DenyStateWrites"
    ])
    error_message = "DenyStateWrites must deny every S3 action but Get and List on the state bucket and its objects, the lock file included."
  }
}

run "prd" {
  command = plan

  variables {
    env               = "prd"
    oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/token.actions.githubusercontent.com"
    state_bucket      = "svp-tfstate-000000000000-ap-southeast-1"
    state_kms_key_arn = "arn:aws:kms:ap-southeast-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  }

  # The mock caller stays in account 111111111111: the media bucket follows it, the state follows state_bucket.
  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.deny.statement :
      toset(s.not_resources) == toset([
        "arn:aws:s3:::svp-tfstate-000000000000-ap-southeast-1/aws/accounts/prd/terraform.tfstate",
        "arn:aws:s3:::svp-tfstate-000000000000-ap-southeast-1/aws/prd/terraform.tfstate",
        "arn:aws:s3:::svp-prd-media-111111111111-ap-southeast-1/media/uptime-probe.txt",
      ])
      if s.sid == "DenyObjectReads"
    ])
    error_message = "In prd, DenyObjectReads must spare the prd state keys and the prd uptime probe object."
  }

  assert {
    condition     = toset(one(one(data.aws_iam_policy_document.trust.statement).principals).identifiers) == toset([var.oidc_provider_arn])
    error_message = "In prd, the role must trust the OIDC provider of the prd account."
  }
}

run "env_rejected" {
  command = plan

  variables {
    env = "dev"
  }

  expect_failures = [var.env]
}

run "oidc_provider_rejected" {
  command = plan

  variables {
    oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/gitlab.com"
  }

  expect_failures = [var.oidc_provider_arn]
}

run "subject_wildcard_rejected" {
  command = plan

  variables {
    subject = "repo:anhnvcoder@1000001/svp-infra@2000003:environment:*"
  }

  expect_failures = [var.subject]
}

run "subject_pull_request_rejected" {
  command = plan

  variables {
    subject = "repo:anhnvcoder@1000001/svp-infra@2000003:pull_request"
  }

  expect_failures = [var.subject]
}

run "subject_mutable_rejected" {
  command = plan

  variables {
    subject = "repo:anhnvcoder/svp-infra:environment:terraform-plan"
  }

  expect_failures = [var.subject]
}

run "state_bucket_rejected" {
  command = plan

  variables {
    state_bucket = "svp-stg-media-111111111111-ap-southeast-1"
  }

  expect_failures = [var.state_bucket]
}

# An ARN that names the key by its other name, not its id, split in two: make test refuses a line with that word.
run "state_key_by_name_rejected" {
  command = plan

  variables {
    state_kms_key_arn = join("", ["arn:aws:kms:ap-southeast-1:111111111111:ali", "as/svp-tfstate"])
  }

  expect_failures = [var.state_kms_key_arn]
}
