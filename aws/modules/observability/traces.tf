# Transaction Search, which the OTLP traces endpoint of X-Ray requires: X-Ray writes spans to the log group aws/spans
# (and Application Signals data), which it creates itself
# (https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html).
data "aws_iam_policy_document" "xray_spans" {
  statement {
    sid     = "TransactionSearchXRayAccess"
    effect  = "Allow"
    actions = ["logs:PutLogEvents"]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:aws/spans:*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/application-signals/data:*",
    ]

    principals {
      type        = "Service"
      identifiers = ["xray.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:xray:${local.region}:${local.account_id}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "xray_spans" {
  policy_name     = "${local.name}-xray-transaction-search"
  policy_document = data.aws_iam_policy_document.xray_spans.json
}

# Removing this resource from Terraform leaves the destination as it is in the account.
resource "aws_xray_trace_segment_destination" "this" {
  destination = "CloudWatchLogs"

  depends_on = [aws_cloudwatch_log_resource_policy.xray_spans]
}

# 1 % of spans indexed as trace summaries, the share X-Ray indexes for free.
resource "aws_xray_indexing_rule" "default" {
  name = "Default"

  rule {
    probabilistic {
      desired_sampling_percentage = 1
    }
  }

  depends_on = [aws_xray_trace_segment_destination.this]
}
