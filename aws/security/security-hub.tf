# Security Hub CSPM with central configuration. Designating svp-security in aws/org turned Security Hub on in this
# account, so there is no aws_securityhub_account here.

# The home region aggregates us-east-1; central configuration takes the aggregation region as its home region.
resource "aws_securityhub_finding_aggregator" "this" {
  linking_mode      = "SPECIFIED_REGIONS"
  specified_regions = ["us-east-1"]
}

resource "aws_securityhub_organization_configuration" "this" {
  # Central configuration: configuration policies decide, so both auto-enable switches stay off.
  auto_enable           = false
  auto_enable_standards = "NONE"

  organization_configuration {
    configuration_type = "CENTRAL"
  }

  depends_on = [aws_securityhub_finding_aggregator.this]
}

resource "aws_securityhub_configuration_policy" "this" {
  name        = "svp-security-standards"
  description = "FSBP v1.0.0 and CIS AWS Foundations Benchmark v5.0.0 in every account; new controls on"

  configuration_policy {
    service_enabled = true
    enabled_standard_arns = [
      "arn:aws:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0",
      "arn:aws:securityhub:${var.region}::standards/cis-aws-foundations-benchmark/v/5.0.0",
    ]

    # A disabled list rather than an enabled one, so controls AWS adds later turn on by themselves. These three check
    # agents GuardDuty manages itself: the EKS agent is managed in Terraform, and there is no ECS and no EC2 to watch.
    security_controls_configuration {
      disabled_control_identifiers = ["GuardDuty.7", "GuardDuty.12", "GuardDuty.13"]
    }
  }

  depends_on = [aws_securityhub_organization_configuration.this]
}

# The root of the organization: every account and OU, the management account included.
resource "aws_securityhub_configuration_policy_association" "root" {
  target_id = data.aws_organizations_organization.this.roots[0].id
  policy_id = aws_securityhub_configuration_policy.this.id
}

# An account's own association wins over the root's, so the accounts whose security_hub flag is off get this one.
resource "aws_securityhub_configuration_policy" "off" {
  count = length(local.security_hub_off_ids) > 0 ? 1 : 0

  name        = "svp-security-off"
  description = "Security Hub off: the accounts whose security_hub flag is off in aws/paid-features.json"

  configuration_policy {
    service_enabled = false
  }

  depends_on = [aws_securityhub_organization_configuration.this]
}

resource "aws_securityhub_configuration_policy_association" "off" {
  for_each = toset(local.security_hub_off_ids)

  target_id = each.key
  policy_id = aws_securityhub_configuration_policy.off[0].id
}
