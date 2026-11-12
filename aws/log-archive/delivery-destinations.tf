# Cross-account standard logging of CloudFront: the destination and its policy live in the account of the bucket,
# the delivery source and the delivery in the env account. Each env may create a delivery only to its own destination,
# whose prefix carries its account id, so the stg lifecycle rule matches and no env writes under the other's prefix.
resource "aws_cloudwatch_log_delivery_destination" "cloudfront" {
  for_each = local.env_account_ids

  region = local.buckets.cloudfront.region
  name   = "svp-cloudfront-${each.key}"
  # Set only at creation; Parquet keeps the same layout Athena reads for flow logs.
  output_format = "parquet"

  delivery_destination_configuration {
    destination_resource_arn = "${aws_s3_bucket.log["cloudfront"].arn}/AWSLogs/${each.value}/CloudFront"
  }
}

resource "aws_cloudwatch_log_delivery_destination_policy" "cloudfront" {
  for_each = local.env_account_ids

  region                      = local.buckets.cloudfront.region
  delivery_destination_name   = aws_cloudwatch_log_delivery_destination.cloudfront[each.key].name
  delivery_destination_policy = data.aws_iam_policy_document.cloudfront_destination[each.key].json
}

data "aws_iam_policy_document" "cloudfront_destination" {
  for_each = local.env_account_ids

  statement {
    sid       = "AllowCreateDeliveryFromEnvAccount"
    effect    = "Allow"
    actions   = ["logs:CreateDelivery"]
    resources = [aws_cloudwatch_log_delivery_destination.cloudfront[each.key].arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${each.value}:root"]
    }
  }
}
