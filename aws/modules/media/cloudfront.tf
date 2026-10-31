# CloudFront in front of the media bucket. The URL of an object is https://<domain>/<key>: the gateway joins
# MEDIA_PUBLIC_BASE_URL (https://<domain>) with the key, and the key already starts with media/.

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

# CORS is answered by CloudFront, not by the bucket. The bucket's CORS headers depend on the request's Origin, but the
# Origin is not in the cache key: a copy cached for a request without Origin (an <img>, curl) would then be served
# without Access-Control-Allow-Origin to a player that needs it. So the distribution forwards no viewer header to the
# bucket (no origin request policy), every viewer shares one cached copy, and this policy adds the CORS headers to
# each answer whose Origin is one of the web's origins. Same methods as the bucket rule: GET and HEAD.
resource "aws_cloudfront_response_headers_policy" "media_cors" {
  name    = "${local.buckets["media"]}-cors"
  comment = "CORS of the web client for media"

  cors_config {
    access_control_allow_credentials = false
    access_control_max_age_sec       = 600
    origin_override                  = true

    access_control_allow_headers {
      items = ["*"]
    }

    access_control_allow_methods {
      items = ["GET", "HEAD"]
    }

    access_control_allow_origins {
      items = var.cors_allowed_origins
    }
  }
}

# No WAF web ACL (the finding below): the distribution serves public, immutable HLS objects from a read-only origin,
# and a web ACL costs a monthly fee per ACL and per rule for no rule this content needs. The default *.cloudfront.net
# certificate leaves the viewer TLS policy to CloudFront; a minimum protocol version needs a certificate of our own,
# in ACM us-east-1 with a name of our own, which is a later step.
#trivy:ignore:AWS-0011
resource "aws_cloudfront_distribution" "media" {
  enabled         = true
  comment         = "Media of ${var.name_prefix}"
  price_class     = var.price_class
  http_version    = "http2and3"
  is_ipv6_enabled = true

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
    response_headers_policy_id = aws_cloudfront_response_headers_policy.media_cors.id
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
