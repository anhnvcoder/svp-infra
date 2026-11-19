# Cross-account standard logging of CloudFront: the destination and its policy live in the account of the bucket,
# the delivery source and the delivery in the env account. Each env may create a delivery only to its own destination,
# whose prefix is its account id, so the stg lifecycle rule matches and no env writes under the other's prefix.
resource "aws_cloudwatch_log_delivery_destination" "cloudfront" {
  for_each = local.env_account_ids

  region = local.buckets.cloudfront.region
  name   = "svp-cloudfront-${each.key}"
  # Set only at creation; Parquet keeps the same layout Athena reads for flow logs.
  output_format = "parquet"

  # The prefix after the bucket ARN must be one segment: PutDeliveryDestination rejects any "/" in it. With a prefix,
  # CloudFront adds no AWSLogs/<account>/CloudFront of its own, so the keys are <account>/<suffix path of the delivery>.
  # https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/standard-logging.html (read 2026-11-19)
  delivery_destination_configuration {
    destination_resource_arn = "${aws_s3_bucket.log["cloudfront"].arn}/${each.value}"
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
