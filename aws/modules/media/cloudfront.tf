# CloudFront in front of the media bucket, at media.<domain>. The URL of an object is https://media.<domain>/<key>:
# the gateway joins MEDIA_PUBLIC_BASE_URL with the key, and the key already starts with media/. flat_rate_free picks
# the plan: true subscribes to the flat-rate Free plan (managed CORS policy, no access log), false is pay-as-you-go
# with the module's own headers policy and a standard log. Design notes: aws/modules/media/README.md.

locals {
  # CloudFront takes viewer certificates, and delivers its logs, only in us-east-1.
  global_region = "us-east-1"

  distribution_name = "${var.name_prefix}-media"
  media_domain      = "media.${var.domain}"

  # The viewer policy of the edge module: the newest that still takes TLS 1.2 next to TLS 1.3.
  viewer_tls_policy = "TLSv1.2_2025"

  # Same list as the edge module: every field of the standard log v2 example of the CloudFront guide but cs(Cookie).
  log_record_fields = [
    "date", "time", "x-edge-location", "sc-bytes", "c-ip", "cs-method", "cs(Host)", "cs-uri-stem", "sc-status",
    "cs(Referer)", "cs(User-Agent)", "cs-uri-query", "x-edge-result-type", "x-edge-request-id", "x-host-header",
    "cs-protocol", "cs-bytes", "time-taken", "x-forwarded-for", "ssl-protocol", "ssl-cipher",
    "x-edge-response-result-type", "cs-protocol-version", "fle-status", "fle-encrypted-fields", "c-port",
    "time-to-first-byte", "x-edge-detailed-result-type", "sc-content-type", "sc-content-len", "sc-range-start",
    "sc-range-end", "c-country", "cache-behavior-path-pattern",
  ]
}

# Signs every request to the bucket, so the bucket can name this distribution in its policy and stay private.
resource "aws_cloudfront_origin_access_control" "media" {
  name                              = local.buckets["media"]
  description                       = "Reads ${local.buckets["media"]}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Managed policy: no query string, cookie or header in the cache key, compressed variants cached, and the TTL taken
# from the object's Cache-Control between 1 second and a year (24 hours when the object sends none). Every object of
# a media version carries max-age=31536000, immutable, so edges keep it for a year.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# CORS is answered by CloudFront, not by the bucket: Origin is not in the cache key, so a copy cached for a request
# without one (an <img>, curl) would reach a player that needs Access-Control-Allow-Origin without it. The Free plan
# takes only managed policies; this one sends Access-Control-Allow-Origin: *, enough for public, immutable objects
# that the player fetches without credentials.
data "aws_cloudfront_response_headers_policy" "simple_cors" {
  count = var.flat_rate_free ? 1 : 0

  name = "Managed-SimpleCORS"
}

# Off the Free plan, CORS names the web's own origins, and the policy adds the security headers of the other names.
resource "aws_cloudfront_response_headers_policy" "media" {
  count = var.flat_rate_free ? 0 : 1

  name    = local.distribution_name
  comment = "CORS and security headers of ${local.media_domain}"

  cors_config {
    access_control_allow_credentials = false
    # Only answers a preflight, which never comes: the distribution takes no OPTIONS and the player sends no header
    # that needs one.
    access_control_allow_headers {
      items = ["*"]
    }
    access_control_allow_methods {
      items = ["GET", "HEAD"]
    }
    access_control_allow_origins {
      items = var.cors_allowed_origins
    }
    origin_override = true
  }

  security_headers_config {
    # No preload: a name on the browsers' preload list takes months to leave it.
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }

    content_type_options {
      override = true
    }
  }
}

resource "aws_acm_certificate" "viewer" {
  region            = local.global_region
  domain_name       = local.media_domain
  validation_method = "DNS"
  key_algorithm     = "EC_prime256v1"

  tags = {
    Name = local.distribution_name
  }

  # The distribution always holds a certificate: the new one is issued and attached before the old one goes.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  zone_id = var.hosted_zone_id
  name    = one(aws_acm_certificate.viewer.domain_validation_options).resource_record_name
  type    = one(aws_acm_certificate.viewer.domain_validation_options).resource_record_type
  records = [one(aws_acm_certificate.viewer.domain_validation_options).resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "viewer" {
  region                  = local.global_region
  certificate_arn         = aws_acm_certificate.viewer.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]
}

resource "aws_cloudfront_distribution" "media" {
  enabled = true
  comment = local.distribution_name
  aliases = [local.media_domain]
  # Subscribing to a flat-rate plan moves the distribution to every edge location; any other class drifts. Off the
  # plan the class stays, so both plans serve from the same edges.
  price_class     = "PriceClass_All"
  http_version    = "http2and3"
  is_ipv6_enabled = true
  web_acl_id      = var.web_acl_arn

  origin {
    origin_id                = "media"
    domain_name              = aws_s3_bucket.this["media"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.media.id
  }

  default_cache_behavior {
    target_origin_id = "media"
    # The player only reads; preflights do not happen, since its requests carry no header that needs one.
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    viewer_protocol_policy = "https-only"
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = (var.flat_rate_free ?
    data.aws_cloudfront_response_headers_policy.simple_cors[0].id : aws_cloudfront_response_headers_policy.media[0].id)
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.viewer.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = local.viewer_tls_policy
  }

  tags = {
    Name = local.distribution_name
  }
}

resource "aws_route53_record" "media" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.hosted_zone_id
  name    = local.media_domain
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.media.domain_name
    zone_id                = aws_cloudfront_distribution.media.hosted_zone_id
    evaluate_target_health = false
  }
}

# The flat-rate Free plan: a fixed $0 a month with no overage charge, in place of pay-as-you-go. AWS requires the plan
# to cover exactly one distribution and one web ACL. Both are referenced here, so destroy cancels the plan first, as
# AWS requires before it deletes the distribution or detaches the web ACL.
resource "aws_pricingplanmanager_subscription" "media" {
  count = var.flat_rate_free ? 1 : 0

  plan_family   = "CloudFront"
  plan_tier     = "FREE"
  resource_arns = [aws_cloudfront_distribution.media.arn, var.web_acl_arn]
}

# Pay-as-you-go only, since the Free plan has no access log: standard logs (v2) to the CloudFront log bucket of the
# Log Archive account. The destination and its policy live in that account; this one only declares the source and the
# delivery to the destination's ARN.
resource "aws_cloudwatch_log_delivery_source" "media" {
  count = var.flat_rate_free ? 0 : 1

  region       = local.global_region
  name         = local.distribution_name
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.media.arn
}

resource "aws_cloudwatch_log_delivery" "media" {
  count = var.flat_rate_free ? 0 : 1

  region                   = local.global_region
  delivery_source_name     = aws_cloudwatch_log_delivery_source.media[0].name
  delivery_destination_arn = var.log_delivery_destination_arn
  record_fields            = local.log_record_fields

  s3_delivery_configuration {
    suffix_path                 = "{DistributionId}/{yyyy}/{MM}/{dd}/{HH}"
    enable_hive_compatible_path = true
  }
}
