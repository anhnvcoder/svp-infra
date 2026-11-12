# Standard logs (v2) of both distributions to the CloudFront log bucket of the Log Archive account. The destination
# and its policy live in that account; this one only declares the source and the delivery to the destination's ARN.

resource "aws_cloudwatch_log_delivery_source" "this" {
  for_each = local.sites

  region       = local.global_region
  name         = "${var.name}-${each.key}"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.this[each.key].arn
}

resource "aws_cloudwatch_log_delivery" "this" {
  for_each = local.sites

  region                   = local.global_region
  delivery_source_name     = aws_cloudwatch_log_delivery_source.this[each.key].name
  delivery_destination_arn = var.log_delivery_destination_arn
  record_fields            = local.log_record_fields

  s3_delivery_configuration {
    suffix_path                 = "{DistributionId}/{yyyy}/{MM}/{dd}/{HH}"
    enable_hive_compatible_path = true
  }
}
