# The public way in to the web and the API: one CloudFront distribution per name, both reaching Envoy through a VPC
# origin and an internal ALB in the edge subnets. Nothing here is reachable from the internet but CloudFront.
# Design notes: aws/modules/edge/README.md.

locals {
  # CloudFront takes viewer certificates, and delivers its logs, only in us-east-1.
  global_region = "us-east-1"

  # What differs between the two distributions. The web sets its own CSP with a nonce and a few security headers, so
  # its edge policy only fills in what a response lacks; the gateway sets none, so the API policy is their only source.
  sites = {
    web = {
      alias                   = var.domain
      cached_paths            = ["/_next/static/*"]
      header_override         = false
      content_security_policy = null
    }
    api = {
      alias                   = "api.${var.domain}"
      cached_paths            = []
      header_override         = true
      content_security_policy = "default-src 'none'; frame-ancestors 'none'"
    }
  }

  # The newest viewer policy that still takes TLS 1.2 next to TLS 1.3, and the post-quantum ALB policy AWS recommends.
  viewer_tls_policy = "TLSv1.2_2025"
  alb_tls_policy    = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"

  # Container ports of the Envoy pods behind the target group: the HTTPS listener and the readiness probe.
  envoy_ports = {
    https  = 10443
    health = 19003
  }

  # Every field of the standard log v2 example of the CloudFront guide but cs(Cookie), which would store the web's
  # session cookie. The media module keeps the same list.
  log_record_fields = [
    "date", "time", "x-edge-location", "sc-bytes", "c-ip", "cs-method", "cs(Host)", "cs-uri-stem", "sc-status",
    "cs(Referer)", "cs(User-Agent)", "cs-uri-query", "x-edge-result-type", "x-edge-request-id", "x-host-header",
    "cs-protocol", "cs-bytes", "time-taken", "x-forwarded-for", "ssl-protocol", "ssl-cipher",
    "x-edge-response-result-type", "cs-protocol-version", "fle-status", "fle-encrypted-fields", "c-port",
    "time-to-first-byte", "x-edge-detailed-result-type", "sc-content-type", "sc-content-len", "sc-range-start",
    "sc-range-end", "c-country", "cache-behavior-path-pattern",
  ]
}
