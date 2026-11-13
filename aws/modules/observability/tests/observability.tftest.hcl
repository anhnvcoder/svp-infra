# What the observability module of an env guarantees: who may use the key and how, encryption of the workspace and the
# log group, Transaction Search, a Grafana workspace outside any VPC whose role only reads, then one plan per validation
# rule with a value that only that rule rejects. The AWS provider is a mock: nothing reaches an account. Policies are
# asserted through the arguments of their aws_iam_policy_document data sources (the mock returns a fixed JSON for them).

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
  env                      = "stg"
  amp_retention_days       = 31
  log_retention_days       = 7
  span_retention_days      = 7
  platform_admin_group_id  = "00000000-0000-0000-0000-000000000001"
  platform_viewer_group_id = "00000000-0000-0000-0000-000000000002"

  # The ARN of the key and of the workspace are known in a plan up to their generated id.
  key_arn_prefix       = "arn:aws:kms:ap-southeast-1:111111111111:key/"
  workspace_arn_prefix = "arn:aws:aps:ap-southeast-1:111111111111:workspace/"
  log_group_arn        = "arn:aws:logs:ap-southeast-1:111111111111:log-group:/svp/stg/otel"

  # Every KMS action that reads or writes data, or lets another principal do so.
  crypto_actions = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey", "kms:GenerateDataKey*", "kms:CreateGrant", "kms:*"]

  # Every action the Grafana role may hold: reads of AMP, CloudWatch Logs Insights and CloudWatch metrics.
  grafana_read_actions = [
    "aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata", "aps:ListRules", "aps:ListAlerts",
    "logs:StartQuery", "logs:StopQuery", "logs:GetQueryResults", "logs:GetLogGroupFields", "logs:DescribeLogGroups",
    "cloudwatch:GetMetricData", "cloudwatch:ListMetrics", "kms:Decrypt", "kms:DescribeKey",
  ]
}

run "stg" {
  command = plan

  # Key: the account administers it, uses it only through AMP and CloudWatch Logs; CloudWatch Logs only for the group.
  assert {
    condition = alltrue(flatten([for s in data.aws_iam_policy_document.observability_key.statement : [
      for p in s.principals : (p.type == "AWS" && toset(p.identifiers) == toset(["arn:aws:iam::111111111111:root"])) ||
      (p.type == "Service" && toset(p.identifiers) == toset(["logs.ap-southeast-1.amazonaws.com"]))
    ]]))
    error_message = "Every principal of the key policy must be the account itself or CloudWatch Logs of the region, never \"*\" or another account."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.observability_key.statement :
      length(setintersection(toset(s.actions), toset(var.crypto_actions))) == 0 ||
      anytrue([for c in s.condition : c.variable == "kms:ViaService" || c.variable == "kms:EncryptionContext:aws:logs:arn"])
    ])
    error_message = "A key policy statement that allows using the key must be limited to a service (kms:ViaService) or to the log group (encryption context)."
  }

  assert {
    condition = [for s in data.aws_iam_policy_document.observability_key.statement : [
      s.sid, toset([for c in s.condition : "${c.test} ${c.variable}=${join(",", c.values)}"])
      ]] == [
      ["AccountAdministersKey", toset([])],
      ["AccountUsesKeyThroughPrometheus", toset(["StringEquals kms:ViaService=aps.ap-southeast-1.amazonaws.com", "StringEquals kms:CallerAccount=111111111111"])],
      ["AccountUsesKeyThroughLogs", toset(["StringEquals kms:ViaService=logs.ap-southeast-1.amazonaws.com", "StringEquals kms:CallerAccount=111111111111"])],
      ["LogsEncryptsApplicationLogGroup", toset(["ArnEquals kms:EncryptionContext:aws:logs:arn=${var.log_group_arn}"])],
    ]
    error_message = "The key policy must hold the four statements: administration, use through AMP, use through CloudWatch Logs, CloudWatch Logs for /svp/<env>/otel."
  }

  assert {
    condition     = toset(data.aws_iam_policy_document.observability_key.statement[1].actions) == toset(["kms:DescribeKey", "kms:CreateGrant", "kms:GenerateDataKey", "kms:Decrypt"])
    error_message = "Through AMP the account may only describe the key, create the grants of the workspace, make and decrypt data keys."
  }

  assert {
    condition     = aws_kms_key.observability.enable_key_rotation && aws_kms_key.observability.deletion_window_in_days == 30
    error_message = "The observability key must rotate and wait 30 days before deletion."
  }

  # Encryption of the workspace and the log group with that key. The workspace name sits in an attribute whose name
  # make test refuses on any line, so it is joined.
  assert {
    condition     = lookup(aws_prometheus_workspace.this, join("", ["al", "ias"])) == "svp-stg"
    error_message = "The Prometheus workspace must be named svp-<env>."
  }

  assert {
    condition     = try(startswith(aws_prometheus_workspace.this.kms_key_arn, var.key_arn_prefix), false)
    error_message = "The Prometheus workspace must be encrypted with the observability key."
  }

  assert {
    condition     = aws_prometheus_workspace_configuration.this.retention_period_in_days == 31
    error_message = "The workspace must keep metrics amp_retention_days days."
  }

  assert {
    condition     = try(startswith(aws_cloudwatch_log_group.otel.kms_key_id, var.key_arn_prefix), false)
    error_message = "The application log group must be encrypted with the observability key."
  }

  assert {
    condition = (
      aws_cloudwatch_log_group.otel.name == "/svp/stg/otel" &&
      aws_cloudwatch_log_group.otel.log_group_class == "STANDARD" &&
      aws_cloudwatch_log_group.otel.retention_in_days == 7
    )
    error_message = "The application log group must be /svp/<env>/otel, of class STANDARD, kept log_retention_days days."
  }

  assert {
    condition     = aws_cloudwatch_log_stream.otel_collector.name == "otel-collector" && aws_cloudwatch_log_stream.otel_collector.log_group_name == "/svp/stg/otel"
    error_message = "The log group must hold the stream otel-collector the OTLP endpoint writes to."
  }

  # Transaction Search.
  assert {
    condition = (
      length(data.aws_iam_policy_document.xray_spans.statement) == 1 &&
      toset(data.aws_iam_policy_document.xray_spans.statement[0].actions) == toset(["logs:PutLogEvents"]) &&
      toset(data.aws_iam_policy_document.xray_spans.statement[0].resources) == toset([
        "arn:aws:logs:ap-southeast-1:111111111111:log-group:aws/spans:*",
        "arn:aws:logs:ap-southeast-1:111111111111:log-group:/aws/application-signals/data:*",
      ]) &&
      one(data.aws_iam_policy_document.xray_spans.statement[0].principals).type == "Service" &&
      toset(one(data.aws_iam_policy_document.xray_spans.statement[0].principals).identifiers) == toset(["xray.amazonaws.com"]) &&
      toset([for c in data.aws_iam_policy_document.xray_spans.statement[0].condition : "${c.test} ${c.variable}=${join(",", c.values)}"]) == toset([
        "ArnLike aws:SourceArn=arn:aws:xray:ap-southeast-1:111111111111:*",
        "StringEquals aws:SourceAccount=111111111111",
      ])
    )
    error_message = "X-Ray may only put log events into aws/spans and the Application Signals group, for this account's traces."
  }

  assert {
    condition = (
      aws_xray_trace_segment_destination.this.destination == "CloudWatchLogs" &&
      aws_xray_indexing_rule.default.name == "Default" &&
      one(one(aws_xray_indexing_rule.default.rule).probabilistic).desired_sampling_percentage == 1
    )
    error_message = "Transaction Search must send segments to CloudWatch Logs and index 1 % of spans."
  }

  # Grafana: outside any VPC, IAM Identity Center sign-in, a role of the module, two groups, the operator account.
  assert {
    condition     = length(aws_grafana_workspace.this.vpc_configuration) == 0 && length(aws_grafana_workspace.this.network_access_control) == 0
    error_message = "The Grafana workspace must have no VPC configuration and no network access control."
  }

  assert {
    condition = (
      aws_grafana_workspace.this.name == "svp-stg" &&
      aws_grafana_workspace.this.account_access_type == "CURRENT_ACCOUNT" &&
      toset(aws_grafana_workspace.this.authentication_providers) == toset(["AWS_SSO"]) &&
      aws_grafana_workspace.this.permission_type == "CUSTOMER_MANAGED" &&
      toset(aws_grafana_workspace.this.data_sources) == toset(["PROMETHEUS", "CLOUDWATCH"])
    )
    error_message = "The Grafana workspace must be svp-<env>, IAM Identity Center sign-in, CUSTOMER_MANAGED, with the PROMETHEUS and CLOUDWATCH data sources."
  }

  assert {
    condition = (
      aws_iam_role.grafana.name == "svp-stg-grafana" &&
      toset(one(data.aws_iam_policy_document.grafana_trust.statement).actions) == toset(["sts:AssumeRole"]) &&
      one(one(data.aws_iam_policy_document.grafana_trust.statement).principals).type == "Service" &&
      toset(one(one(data.aws_iam_policy_document.grafana_trust.statement).principals).identifiers) == toset(["grafana.amazonaws.com"]) &&
      toset([for c in one(data.aws_iam_policy_document.grafana_trust.statement).condition : "${c.test} ${c.variable}=${join(",", c.values)}"]) == toset(["StringEquals aws:SourceAccount=111111111111"])
    )
    error_message = "Only Amazon Managed Grafana of this account may assume the role svp-<env>-grafana."
  }

  assert {
    condition = alltrue(flatten([for s in data.aws_iam_policy_document.grafana.statement : [
      for a in s.actions : contains(var.grafana_read_actions, a)
    ]])) && alltrue([for s in data.aws_iam_policy_document.grafana.statement : s.effect == null || s.effect == "Allow"])
    error_message = "The Grafana role may hold only read actions: no remote write, rule, log write or key administration."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.grafana.statement :
      !contains(s.resources, "*") || toset(s.actions) == toset(["logs:StopQuery", "logs:DescribeLogGroups", "cloudwatch:GetMetricData", "cloudwatch:ListMetrics"])
    ])
    error_message = "Only actions without a resource type may name the resource \"*\"."
  }

  assert {
    condition = (
      try(startswith(one(data.aws_iam_policy_document.grafana.statement[0].resources), var.workspace_arn_prefix), false) &&
      contains(data.aws_iam_policy_document.grafana.statement[1].resources, var.log_group_arn) &&
      contains(data.aws_iam_policy_document.grafana.statement[1].resources, "arn:aws:logs:ap-southeast-1:111111111111:log-group:aws/spans") &&
      alltrue([for r in data.aws_iam_policy_document.grafana.statement[1].resources : startswith(r, "arn:aws:logs:ap-southeast-1:111111111111:log-group:")])
    )
    error_message = "The Grafana role must read this env's workspace and this account's log groups."
  }

  # The role uses the key only through CloudWatch Logs (the log groups) and AMP (the workspace).
  assert {
    condition = [for s in data.aws_iam_policy_document.grafana.statement : [
      s.sid, toset(s.actions), alltrue([for r in s.resources : startswith(r, var.key_arn_prefix)]),
      toset([for c in s.condition : "${c.test} ${c.variable}=${join(",", c.values)}"])
      ] if anytrue([for a in s.actions : startswith(a, "kms:")])] == [
      ["DecryptLogsThroughCloudWatchLogs", toset(["kms:Decrypt"]), true, toset(["StringEquals kms:ViaService=logs.ap-southeast-1.amazonaws.com"])],
      ["DecryptMetricsThroughPrometheus", toset(["kms:Decrypt", "kms:DescribeKey"]), true, toset(["StringEquals kms:ViaService=aps.ap-southeast-1.amazonaws.com"])],
    ]
    error_message = "The Grafana role must use the observability key only through CloudWatch Logs (decrypt) and AMP (decrypt, describe)."
  }

  assert {
    condition = (
      aws_grafana_role_association.admin.role == "ADMIN" && aws_grafana_role_association.admin.group_ids == toset(["00000000-0000-0000-0000-000000000001"]) &&
      aws_grafana_role_association.viewer.role == "VIEWER" && aws_grafana_role_association.viewer.group_ids == toset(["00000000-0000-0000-0000-000000000002"]) &&
      aws_grafana_role_association.admin.user_ids == null && aws_grafana_role_association.viewer.user_ids == null
    )
    error_message = "The admin group must get ADMIN, the viewer group VIEWER, and no user a role of their own."
  }

  assert {
    condition     = aws_grafana_workspace_service_account.operator.name == "svp-grafana-operator" && aws_grafana_workspace_service_account.operator.grafana_role == "ADMIN"
    error_message = "Grafana Operator must sign in as the service account svp-grafana-operator with the ADMIN role, the only one that may add data sources."
  }

  assert {
    condition     = output.log_group_name == "/svp/stg/otel"
    error_message = "The log_group_name output must be the application log group."
  }

  assert {
    condition     = output.spans_retention_command == "AWS_PROFILE=anhnv-stg aws logs put-retention-policy --log-group-name aws/spans --retention-in-days 7 --region ap-southeast-1"
    error_message = "The spans_retention_command output must set the retention of aws/spans to span_retention_days in this env's account and region."
  }
}

run "prd" {
  command = plan

  variables {
    env                     = "prd"
    amp_retention_days      = 150
    log_retention_days      = 30
    span_retention_days     = 30
    platform_admin_group_id = "0123456789-00000000-0000-0000-0000-000000000003"
  }

  assert {
    condition = (
      lookup(aws_prometheus_workspace.this, join("", ["al", "ias"])) == "svp-prd" &&
      aws_prometheus_workspace_configuration.this.retention_period_in_days == 150 &&
      aws_cloudwatch_log_group.otel.name == "/svp/prd/otel" &&
      aws_cloudwatch_log_group.otel.retention_in_days == 30 &&
      aws_grafana_workspace.this.name == "svp-prd" &&
      aws_iam_role.grafana.name == "svp-prd-grafana"
    )
    error_message = "prd must name every resource svp-prd and keep its own retention."
  }

  assert {
    condition     = aws_grafana_role_association.admin.group_ids == toset(["0123456789-00000000-0000-0000-0000-000000000003"])
    error_message = "A group id with the 10-digit prefix of an Identity Store must be accepted as it is."
  }

  assert {
    condition     = output.spans_retention_command == "AWS_PROFILE=anhnv-prd aws logs put-retention-policy --log-group-name aws/spans --retention-in-days 30 --region ap-southeast-1"
    error_message = "The spans_retention_command output must use the prd profile and retention."
  }
}

run "env_rejected" {
  command = plan

  variables {
    env = "dev"
  }

  expect_failures = [var.env]
}

run "amp_retention_zero_rejected" {
  command = plan

  variables {
    amp_retention_days = 0
  }

  expect_failures = [var.amp_retention_days]
}

run "amp_retention_too_long_rejected" {
  command = plan

  variables {
    amp_retention_days = 1096
  }

  expect_failures = [var.amp_retention_days]
}

run "amp_retention_fraction_rejected" {
  command = plan

  variables {
    amp_retention_days = 30.5
  }

  expect_failures = [var.amp_retention_days]
}

run "log_retention_rejected" {
  command = plan

  variables {
    log_retention_days = 10
  }

  expect_failures = [var.log_retention_days]
}

run "span_retention_rejected" {
  command = plan

  variables {
    span_retention_days = 8
  }

  expect_failures = [var.span_retention_days]
}

run "admin_group_rejected" {
  command = plan

  variables {
    platform_admin_group_id = "svp-platform-admins"
  }

  expect_failures = [var.platform_admin_group_id]
}

run "viewer_group_rejected" {
  command = plan

  variables {
    platform_viewer_group_id = "00000000-0000-0000-0000-00000000000"
  }

  expect_failures = [var.platform_viewer_group_id]
}
