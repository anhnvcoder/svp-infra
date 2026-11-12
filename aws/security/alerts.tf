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
