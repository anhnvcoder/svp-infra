################################################################################
# AWS Config aggregator
################################################################################

data "aws_iam_policy_document" "config_aggregator_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.security_account_id]
    }
  }
}

# The svp-security- prefix puts the role under the baseline service control policy.
resource "aws_iam_role" "config_aggregator" {
  name               = "svp-security-config-aggregator"
  description        = "AWS Config: reads the organization for the aggregator svp-org"
  assume_role_policy = data.aws_iam_policy_document.config_aggregator_trust.json
}

resource "aws_iam_role_policy_attachment" "config_aggregator" {
  role       = aws_iam_role.config_aggregator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRoleForOrganizations"
}

# Every region, not only the two with recorders: should a recorder ever run elsewhere (the management account is not
# under the region policy), its resources still show up here. Aggregation is free.
resource "aws_config_configuration_aggregator" "org" {
  name = "svp-org"

  organization_aggregation_source {
    all_regions = true
    role_arn    = aws_iam_role.config_aggregator.arn
  }

  depends_on = [aws_iam_role_policy_attachment.config_aggregator]
}

################################################################################
# IAM Access Analyzer
################################################################################

# External access only: the unused access analyzer is billed per role, and every session makes and removes roles.
resource "aws_accessanalyzer_analyzer" "org" {
  for_each = local.regions

  region        = each.key
  analyzer_name = "svp-org"
  type          = "ORGANIZATION"
}
