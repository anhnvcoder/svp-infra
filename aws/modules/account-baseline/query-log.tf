# Public DNS query log of the zone. Route 53 writes only to a log group in us-east-1, through a CloudWatch Logs resource
# policy (https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/query-logs.html).

locals {
  query_log_count = var.query_log_enabled ? 1 : 0
  query_log_group = "/aws/route53/${var.zone_name}"
}

resource "aws_cloudwatch_log_group" "query_log" {
  count = local.query_log_count

  region            = local.global_region
  name              = local.query_log_group
  retention_in_days = 90
}

# Route 53 writes for this zone of this account only (confused deputy conditions).
data "aws_iam_policy_document" "query_log" {
  count = local.query_log_count

  statement {
    sid       = "Route53QueryLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${local.global_region}:${var.account_id}:log-group:${local.query_log_group}:*"]

    principals {
      type        = "Service"
      identifiers = ["route53.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_route53_zone.env.arn]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "query_log" {
  count = local.query_log_count

  region          = local.global_region
  policy_name     = "svp-route53-query-log"
  policy_document = data.aws_iam_policy_document.query_log[0].json
}

resource "aws_route53_query_log" "this" {
  count = local.query_log_count

  zone_id                  = aws_route53_zone.env.zone_id
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.query_log[0].arn

  # Route 53 checks that it may write to the group when the query log is created.
  depends_on = [aws_cloudwatch_log_resource_policy.query_log]
}
