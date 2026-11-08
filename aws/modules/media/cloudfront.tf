# CloudFront in front of the media bucket. The URL of an object is https://<domain>/<key>: the gateway joins
# MEDIA_PUBLIC_BASE_URL (https://<domain>) with the key, and the key already starts with media/.
# Design notes: aws/modules/media/README.md.

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
# without one (an <img>, curl) would reach a player that needs Access-Control-Allow-Origin without it. The flat-rate
# Free plan takes only managed response headers policies; this one sends Access-Control-Allow-Origin: *, enough for
# public, immutable objects that the player fetches without credentials.
data "aws_cloudfront_response_headers_policy" "simple_cors" {
  name = "Managed-SimpleCORS"
}

resource "aws_cloudfront_distribution" "media" {
  enabled = true
  comment = "Media of ${var.name_prefix}"
  # Subscribing to a flat-rate plan moves the distribution to every edge location; any other class drifts.
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
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    viewer_protocol_policy     = "https-only"
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.simple_cors.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# The flat-rate Free plan: a fixed $0 a month with no overage charge, in place of pay-as-you-go. AWS requires the plan
# to cover exactly one distribution and one web ACL. Both are referenced here, so destroy cancels the plan first, as
# AWS requires before it deletes the distribution or detaches the web ACL.
resource "aws_pricingplanmanager_subscription" "media" {
  plan_family   = "CloudFront"
  plan_tier     = "FREE"
  resource_arns = [aws_cloudfront_distribution.media.arn, var.web_acl_arn]
}
