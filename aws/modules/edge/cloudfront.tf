# One distribution per name, so each carries its own web ACL (bot control for the web, account takeover for the API),
# certificate, headers and log. Nothing is cached but the hashed build files of the web; every request reaches the
# origin with every viewer header, cookie and query string, the Host included, which Envoy routes on, and
# CloudFront-Viewer-Address, which the gateway reads the client IP from. Design notes: aws/modules/edge/README.md.

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewerAndCloudFrontHeaders-2022-06"
}

resource "aws_cloudfront_response_headers_policy" "this" {
  for_each = local.sites

  name    = "${var.name}-${each.key}"
  comment = "Security headers of ${each.value.alias}"

  security_headers_config {
    # No preload: a name on the browsers' preload list takes months to leave it.
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = false
      override                   = each.value.header_override
    }

    content_type_options {
      override = each.value.header_override
    }

    frame_options {
      frame_option = "DENY"
      override     = each.value.header_override
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = each.value.header_override
    }

    dynamic "content_security_policy" {
      for_each = each.value.content_security_policy == null ? [] : [each.value.content_security_policy]

      content {
        content_security_policy = content_security_policy.value
        override                = each.value.header_override
      }
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  for_each = local.sites

  enabled         = true
  comment         = "${var.name}-${each.key}"
  aliases         = [each.value.alias]
  price_class     = "PriceClass_All"
  http_version    = "http2and3"
  is_ipv6_enabled = true
  web_acl_id      = var.web_acl_arns[each.key]

  origin {
    origin_id   = "edge"
    domain_name = aws_lb.this.dns_name

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.this.id
    }
  }

  default_cache_behavior {
    target_origin_id           = "edge"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    viewer_protocol_policy     = "redirect-to-https"
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.this[each.key].id
  }

  dynamic "ordered_cache_behavior" {
    for_each = each.value.cached_paths

    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = "edge"
      allowed_methods            = ["GET", "HEAD"]
      cached_methods             = ["GET", "HEAD"]
      viewer_protocol_policy     = "redirect-to-https"
      compress                   = true
      cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
      response_headers_policy_id = aws_cloudfront_response_headers_policy.this[each.key].id
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.viewer[each.key].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = local.viewer_tls_policy
  }

  tags = {
    Name = "${var.name}-${each.key}"
  }
}
