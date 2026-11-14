################################################################################
# Alert topic
################################################################################

module "alarms" {
  source = "../modules/alarms"

  name               = "svp-security"
  publisher_services = ["events.amazonaws.com"]
  alarm_email        = var.security_alert_email
}

################################################################################
# Security event bus
################################################################################

# The svp-security-* rules of every account forward their events here (security-baseline module).
resource "aws_cloudwatch_event_bus" "security" {
  name        = "svp-security-events"
  description = "Security events forwarded by the svp-security-* rules of every account of the organization"
}

data "aws_iam_policy_document" "security_bus" {
  statement {
    sid       = "OrganizationPutEvents"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.security.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [data.aws_organizations_organization.this.id]
    }
  }
}

resource "aws_cloudwatch_event_bus_policy" "security" {
  event_bus_name = aws_cloudwatch_event_bus.security.name
  policy         = data.aws_iam_policy_document.security_bus.json
}

################################################################################
# Rules to the topic
################################################################################

# Every event on the bus is already one the forwarding rules chose.
resource "aws_cloudwatch_event_rule" "notify" {
  name           = "svp-security-notify"
  description    = "Every security event forwarded to svp-security-events, to the alert topic"
  event_bus_name = aws_cloudwatch_event_bus.security.name
  event_pattern  = jsonencode({ source = [{ prefix = "" }] })
}

resource "aws_cloudwatch_event_target" "notify" {
  rule           = aws_cloudwatch_event_rule.notify.name
  event_bus_name = aws_cloudwatch_event_bus.security.name
  target_id      = "svp-security-alarms"
  arn            = module.alarms.topic_arn

  input_transformer {
    input_paths = {
      detail_type = "$.detail-type"
      account     = "$.account"
      region      = "$.region"
      event_name  = "$.detail.eventName"
      principal   = "$.detail.userIdentity.arn"
      error_code  = "$.detail.errorCode"
    }
    input_template = "\"svp-security: <detail_type> <event_name> account <account> region <region> by <principal> error <error_code>. Runbook: ${local.runbook_url}\""
  }
}

# Security Hub sends every new finding and each update of it; only new, active, high or critical findings of GuardDuty
# and Access Analyzer reach email. Failed controls are read on the Security Hub console, as the runbook says.
resource "aws_cloudwatch_event_rule" "findings" {
  name        = "svp-security-findings"
  description = "New high or critical GuardDuty and Access Analyzer findings of the organization, to the alert topic"
  event_pattern = jsonencode({
    source        = ["aws.securityhub"]
    "detail-type" = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity    = { Label = ["HIGH", "CRITICAL"] }
        RecordState = ["ACTIVE"]
        Workflow    = { Status = ["NEW"] }
        ProductName = ["GuardDuty", "IAM Access Analyzer"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "findings" {
  rule      = aws_cloudwatch_event_rule.findings.name
  target_id = "svp-security-alarms"
  arn       = module.alarms.topic_arn

  input_transformer {
    input_paths = {
      title    = "$.detail.findings[0].Title"
      severity = "$.detail.findings[0].Severity.Label"
      account  = "$.detail.findings[0].AwsAccountId"
      region   = "$.detail.findings[0].Region"
      product  = "$.detail.findings[0].ProductName"
    }
    input_template = "\"svp-security finding <severity> <product>: <title>, account <account> region <region>. Runbook: ${local.runbook_url}\""
  }
}

################################################################################
# GuardDuty findings of accounts without Security Hub
################################################################################

# svp-security-guardduty-findings: GuardDuty imports its findings into the Security Hub of the same account, so an
# account whose security_hub flag is off never reaches the rule above. The delegated administrator gets the findings
# of its members in each region.
locals {
  guardduty_finding_regions = length(local.security_hub_off_ids) > 0 ? local.regions : toset([])
  guardduty_forward_regions = [for r in local.guardduty_finding_regions : r if r != var.region]
}

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  for_each = local.guardduty_finding_regions

  region      = each.key
  name        = "svp-security-guardduty-findings"
  description = "High or critical GuardDuty findings of the accounts whose Security Hub is off, to the alert topic"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      accountId = local.security_hub_off_ids
      # Severity is a number here: high is 7.0 to 8.9, critical 9.0 and above.
      severity = [{ numeric = [">=", 7] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_findings" {
  for_each = { for r in local.guardduty_finding_regions : r => r if r == var.region }

  region    = each.key
  rule      = aws_cloudwatch_event_rule.guardduty_findings[each.key].name
  target_id = "svp-security-alarms"
  arn       = module.alarms.topic_arn

  input_transformer {
    input_paths = {
      title    = "$.detail.title"
      severity = "$.detail.severity"
      account  = "$.detail.accountId"
      region   = "$.detail.region"
    }
    input_template = "\"svp-security finding <severity> GuardDuty: <title>, account <account> region <region>. Runbook: ${local.runbook_url}\""
  }
}

# A rule cannot target a topic of another region, so findings of the other region go to the security bus, whose rule
# svp-security-notify sends them on. The forwarder role of aws/baseline already holds the name svp-security-forwarder.
data "aws_iam_policy_document" "guardduty_forwarder_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.security_account_id]
    }
  }
}

resource "aws_iam_role" "guardduty_forwarder" {
  count = length(local.guardduty_forward_regions) > 0 ? 1 : 0

  name               = "svp-security-guardduty-forwarder"
  description        = "EventBridge: forwards GuardDuty findings of other regions to the security event bus"
  assume_role_policy = data.aws_iam_policy_document.guardduty_forwarder_trust.json
}

data "aws_iam_policy_document" "guardduty_forwarder" {
  statement {
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.security.arn]
  }
}

resource "aws_iam_role_policy" "guardduty_forwarder" {
  count = length(aws_iam_role.guardduty_forwarder)

  name   = "put-security-events"
  role   = aws_iam_role.guardduty_forwarder[0].id
  policy = data.aws_iam_policy_document.guardduty_forwarder.json
}

resource "aws_cloudwatch_event_target" "guardduty_findings_forward" {
  for_each = toset(local.guardduty_forward_regions)

  region    = each.key
  rule      = aws_cloudwatch_event_rule.guardduty_findings[each.key].name
  target_id = "svp-security-events"
  arn       = aws_cloudwatch_event_bus.security.arn
  role_arn  = aws_iam_role.guardduty_forwarder[0].arn

  # The role must be able to put events before the first event arrives.
  depends_on = [aws_iam_role_policy.guardduty_forwarder]
}
