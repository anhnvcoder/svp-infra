# What the edge of an env guarantees: an internal ALB that only CloudFront reaches, over HTTPS only; one distribution
# per name with its own certificate, TLS policy, headers and log without cookies; then one plan per validation rule
# with a value that only that rule rejects. The AWS provider is a mock: nothing reaches an account. A plan cannot
# prove that AWS accepts the managed policy names or that a VPC origin deploys.

mock_provider "aws" {
  mock_data "aws_cloudfront_origin_request_policy" {
    defaults = {
      id = "33f36d7e-f396-46d9-90e0-52428a34d9dc"
    }
  }
}

variables {
  name                         = "svp-stg"
  domain                       = "svp.example"
  hosted_zone_id               = "Z0123456789ABCDEFGHIJ"
  vpc_id                       = "vpc-0123456789abcdef0"
  subnet_ids                   = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1", "subnet-0123456789abcdef2"]
  node_security_group_id       = "sg-0123456789abcdef0"
  log_delivery_destination_arn = "arn:aws:logs:us-east-1:111111111111:delivery-destination:svp-cloudfront-stg"
  alb_deletion_protection      = false

  web_acl_arns = {
    web = "arn:aws:wafv2:us-east-1:000000000000:global/webacl/svp-stg-web/a1b2c3d4-5678-90ab-cdef-111111111111"
    api = "arn:aws:wafv2:us-east-1:000000000000:global/webacl/svp-stg-api/a1b2c3d4-5678-90ab-cdef-222222222222"
  }
}

# The origin: internal, HTTPS only, reachable from CloudFront only, and free of any tag of the Load Balancer Controller.
run "origin" {
  command = plan

  assert {
    condition     = aws_lb.this.internal && aws_lb.this.load_balancer_type == "application" && aws_lb.this.name == "svp-stg-edge"
    error_message = "The origin must be an internal Application Load Balancer named <name>-edge."
  }

  assert {
    condition     = aws_lb.this.drop_invalid_header_fields && aws_lb.this.desync_mitigation_mode == "defensive" && !aws_lb.this.enable_deletion_protection
    error_message = "The ALB must drop invalid header fields, mitigate desync in defensive mode and take deletion protection from the variable."
  }

  assert {
    condition     = length(aws_lb.this.subnets) == 3
    error_message = "The ALB must sit in every edge subnet."
  }

  assert {
    condition = (aws_lb_listener.https.protocol == "HTTPS" && aws_lb_listener.https.port == 443 &&
    aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09")
    error_message = "The only listener must be HTTPS on 443 with the TLS policy of the ADR."
  }

  assert {
    condition = (aws_lb_target_group.envoy.name == "svp-stg-envoy" && aws_lb_target_group.envoy.target_type == "ip" &&
      aws_lb_target_group.envoy.protocol == "HTTPS" && aws_lb_target_group.envoy.port == 443 &&
      aws_lb_target_group.envoy.health_check[0].protocol == "HTTP" && aws_lb_target_group.envoy.health_check[0].port == "19003" &&
    aws_lb_target_group.envoy.health_check[0].path == "/ready")
    error_message = "The target group must be <name>-envoy, of type ip, HTTPS 443, with the HTTP health check on 19003 /ready."
  }

  assert {
    condition = (aws_vpc_security_group_ingress_rule.alb_https.from_port == 443 && aws_vpc_security_group_ingress_rule.alb_https.to_port == 443 &&
      aws_vpc_security_group_ingress_rule.alb_https.prefix_list_id == data.aws_ec2_managed_prefix_list.cloudfront.id &&
      aws_vpc_security_group_ingress_rule.alb_https.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.alb_https.cidr_ipv6 == null &&
    data.aws_ec2_managed_prefix_list.cloudfront.name == "com.amazonaws.global.cloudfront.origin-facing")
    error_message = "The ALB security group must let in TCP 443 from the CloudFront origin-facing prefix list only, never from a CIDR such as 0.0.0.0/0."
  }

  assert {
    condition = alltrue([for r in aws_vpc_security_group_egress_rule.alb_to_envoy : r.referenced_security_group_id == var.node_security_group_id && r.cidr_ipv4 == null]) && (
    toset([for r in aws_vpc_security_group_egress_rule.alb_to_envoy : r.from_port]) == toset([10443, 19003]))
    error_message = "The ALB may only open connections to the node security group, on 10443 and 19003."
  }

  assert {
    condition = alltrue([for r in aws_vpc_security_group_ingress_rule.envoy_from_alb : r.security_group_id == var.node_security_group_id && r.cidr_ipv4 == null]) && (
    toset([for r in aws_vpc_security_group_ingress_rule.envoy_from_alb : r.from_port]) == toset([10443, 19003]))
    error_message = "The node security group must let the ALB in on 10443 and 19003, and nothing else."
  }

  assert {
    condition = alltrue([for t in concat(keys(aws_lb.this.tags), keys(aws_lb_target_group.envoy.tags), keys(aws_lb_listener.https.tags)) :
    !startswith(t, "elbv2.k8s.aws/")])
    error_message = "The ALB, its listener and the target group must carry no tag of the Load Balancer Controller (elbv2.k8s.aws/*)."
  }

  assert {
    condition = (aws_cloudfront_vpc_origin.this.vpc_origin_endpoint_config[0].name == "svp-stg-edge" &&
      aws_cloudfront_vpc_origin.this.vpc_origin_endpoint_config[0].origin_protocol_policy == "https-only" &&
    aws_cloudfront_vpc_origin.this.vpc_origin_endpoint_config[0].origin_ssl_protocols[0].items == toset(["TLSv1.2"]))
    error_message = "The VPC origin must be <name>-edge, HTTPS only, TLSv1.2."
  }
}

run "deletion_protection_on" {
  command = plan

  variables {
    alb_deletion_protection = true
  }

  assert {
    condition     = aws_lb.this.enable_deletion_protection
    error_message = "alb_deletion_protection = true must protect the ALB."
  }
}

# Attribute names below are built with join: the guard of make test refuses any line that holds the word naming a
# provider configuration, and CloudFront and Route 53 use that word for alternate names.

# Two distributions, each with exactly one alternate name, its own certificate in us-east-1 and the viewer TLS policy.
run "distributions" {
  command = plan

  assert {
    condition     = length(aws_cloudfront_distribution.this) == 2
    error_message = "The module must create exactly the web and api distributions."
  }

  assert {
    condition = (aws_cloudfront_distribution.this["web"][join("", ["ali", "ases"])] == toset(["svp.example"]) &&
    aws_cloudfront_distribution.this["api"][join("", ["ali", "ases"])] == toset(["api.svp.example"]))
    error_message = "Each distribution must have exactly one alternate name: <domain> for web, api.<domain> for api."
  }

  assert {
    condition = alltrue([for k, d in aws_cloudfront_distribution.this :
      d.comment == "svp-stg-${k}" && d.tags["Name"] == "svp-stg-${k}" && d.web_acl_id == var.web_acl_arns[k] &&
    d.http_version == "http2and3" && d.is_ipv6_enabled && d.price_class == "PriceClass_All"])
    error_message = "Each distribution must be named <name>-<site>, carry the web ACL of its name, and serve HTTP/2 and 3 over IPv6 at every edge location."
  }

  assert {
    condition = alltrue([for d in aws_cloudfront_distribution.this :
    d.viewer_certificate[0].minimum_protocol_version == "TLSv1.2_2025" && d.viewer_certificate[0].ssl_support_method == "sni-only"])
    error_message = "Every distribution must use the viewer TLS policy TLSv1.2_2025 with SNI."
  }

  assert {
    condition = alltrue([for d in aws_cloudfront_distribution.this :
      d.default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https" &&
      d.default_cache_behavior[0].cache_policy_id == data.aws_cloudfront_cache_policy.caching_disabled.id &&
      d.default_cache_behavior[0].origin_request_policy_id == data.aws_cloudfront_origin_request_policy.all_viewer.id &&
    length(d.default_cache_behavior[0].allowed_methods) == 7])
    error_message = "The default behavior must redirect to HTTPS, take every method, cache nothing and forward every viewer header."
  }

  assert {
    condition     = data.aws_cloudfront_origin_request_policy.all_viewer.name == "Managed-AllViewerAndCloudFrontHeaders-2022-06"
    error_message = "The origin request policy must be Managed-AllViewerAndCloudFrontHeaders-2022-06, which adds CloudFront-Viewer-Address."
  }

  assert {
    condition = (length(aws_cloudfront_distribution.this["api"].ordered_cache_behavior) == 0 &&
      length(aws_cloudfront_distribution.this["web"].ordered_cache_behavior) == 1 &&
      aws_cloudfront_distribution.this["web"].ordered_cache_behavior[0].path_pattern == "/_next/static/*" &&
      aws_cloudfront_distribution.this["web"].ordered_cache_behavior[0].cache_policy_id == data.aws_cloudfront_cache_policy.caching_optimized.id &&
      data.aws_cloudfront_cache_policy.caching_optimized.name == "Managed-CachingOptimized" &&
    aws_cloudfront_distribution.this["web"].ordered_cache_behavior[0].origin_request_policy_id == data.aws_cloudfront_origin_request_policy.all_viewer.id)
    error_message = "Only the web caches, and only /_next/static/* with Managed-CachingOptimized, still forwarding every viewer header."
  }

  assert {
    condition = (length(aws_acm_certificate.viewer) == 2 && alltrue([for k, c in aws_acm_certificate.viewer :
      c.region == "us-east-1" && c.domain_name == (k == "web" ? "svp.example" : "api.svp.example") && c.key_algorithm == "EC_prime256v1" &&
    c.validation_method == "DNS"]))
    error_message = "Each distribution must have one ECDSA P-256 certificate in us-east-1 for its own name alone, validated by DNS."
  }

  assert {
    # The region of the ALB certificate is the provider's, known only after apply under the mock.
    condition = (aws_acm_certificate.alb.domain_name == "svp.example" &&
    aws_acm_certificate.alb.subject_alternative_names == toset(["api.svp.example"]) && aws_acm_certificate.alb.key_algorithm == "EC_prime256v1")
    error_message = "The ALB certificate must be for <domain> and api.<domain>, ECDSA P-256."
  }
}

# One validation record per name, shared by the certificates of both regions; an A and an AAAA record per name, each
# pointing at its distribution.
run "dns" {
  command = plan

  assert {
    condition     = length(aws_route53_record.validation) == 2 && alltrue([for r in aws_route53_record.validation : r.zone_id == var.hosted_zone_id])
    error_message = "Each name must get exactly one validation record, in the env's zone."
  }

  assert {
    condition = length(aws_route53_record.site) == 4 && alltrue([for r in aws_route53_record.site :
    r.zone_id == var.hosted_zone_id && contains(["A", "AAAA"], r.type) && !r[join("", ["ali", "as"])][0].evaluate_target_health])
    error_message = "Each name must get an A and an AAAA record in the env's zone, pointing at its distribution."
  }

  assert {
    condition = (toset([for r in aws_route53_record.site : "${r.name}/${r.type}"]) ==
    toset(["svp.example/A", "svp.example/AAAA", "api.svp.example/A", "api.svp.example/AAAA"]))
    error_message = "The records of the distributions must be <domain> and api.<domain>, A and AAAA."
  }
}

# The response headers of the ADR: the API policy overrides, the web policy only fills in, and only the API sets a CSP.
run "headers" {
  command = plan

  assert {
    condition = alltrue([for k, p in aws_cloudfront_response_headers_policy.this :
      p.name == "svp-stg-${k}" &&
      p.security_headers_config[0].strict_transport_security[0].access_control_max_age_sec == 63072000 &&
      p.security_headers_config[0].strict_transport_security[0].include_subdomains &&
      !p.security_headers_config[0].strict_transport_security[0].preload &&
      p.security_headers_config[0].frame_options[0].frame_option == "DENY" &&
      p.security_headers_config[0].referrer_policy[0].referrer_policy == "strict-origin-when-cross-origin" &&
    length(p.security_headers_config[0].content_type_options) == 1])
    error_message = "Both policies must send HSTS for two years with subdomains and no preload, nosniff, DENY and strict-origin-when-cross-origin."
  }

  assert {
    condition = (length(aws_cloudfront_response_headers_policy.this["web"].security_headers_config[0].content_security_policy) == 0 &&
      aws_cloudfront_response_headers_policy.this["api"].security_headers_config[0].content_security_policy[0].content_security_policy == "default-src 'none'; frame-ancestors 'none'" &&
    aws_cloudfront_response_headers_policy.this["api"].security_headers_config[0].content_security_policy[0].override)
    error_message = "Only the API policy sets a CSP, default-src 'none'; frame-ancestors 'none', overriding the origin."
  }

  assert {
    condition = (!aws_cloudfront_response_headers_policy.this["web"].security_headers_config[0].strict_transport_security[0].override &&
      !aws_cloudfront_response_headers_policy.this["web"].security_headers_config[0].content_type_options[0].override &&
      !aws_cloudfront_response_headers_policy.this["web"].security_headers_config[0].frame_options[0].override &&
      !aws_cloudfront_response_headers_policy.this["web"].security_headers_config[0].referrer_policy[0].override &&
      aws_cloudfront_response_headers_policy.this["api"].security_headers_config[0].strict_transport_security[0].override &&
      aws_cloudfront_response_headers_policy.this["api"].security_headers_config[0].content_type_options[0].override &&
      aws_cloudfront_response_headers_policy.this["api"].security_headers_config[0].frame_options[0].override &&
    aws_cloudfront_response_headers_policy.this["api"].security_headers_config[0].referrer_policy[0].override)
    error_message = "The web policy must never override a header the web sets; the API policy must override every header."
  }
}

# Standard logs v2 from us-east-1 to the destination of the Log Archive account, without cookies.
run "logs" {
  command = plan

  assert {
    condition = length(aws_cloudwatch_log_delivery_source.this) == 2 && alltrue([for k, s in aws_cloudwatch_log_delivery_source.this :
    s.region == "us-east-1" && s.log_type == "ACCESS_LOGS" && s.name == "svp-stg-${k}"])
    error_message = "Each distribution must have an ACCESS_LOGS delivery source <name>-<site> in us-east-1."
  }

  assert {
    condition = length(aws_cloudwatch_log_delivery.this) == 2 && alltrue([for d in aws_cloudwatch_log_delivery.this :
    d.region == "us-east-1" && d.delivery_destination_arn == var.log_delivery_destination_arn])
    error_message = "Each delivery must go from us-east-1 to the given destination."
  }

  assert {
    condition = alltrue([for d in aws_cloudwatch_log_delivery.this :
    !contains(d.record_fields, "cs(Cookie)") && length(d.record_fields) == 34 && contains(d.record_fields, "c-ip")])
    error_message = "The record fields must be the 34 fields of the ADR, never cs(Cookie)."
  }

  assert {
    condition = alltrue([for d in aws_cloudwatch_log_delivery.this :
      d.s3_delivery_configuration[0].suffix_path == "{DistributionId}/{yyyy}/{MM}/{dd}/{HH}" &&
    d.s3_delivery_configuration[0].enable_hive_compatible_path])
    error_message = "Logs must be written under a Hive-style path per distribution and hour."
  }
}

run "name_too_long" {
  command = plan

  variables {
    name = "svp-a-very-long-environment-x"
  }

  expect_failures = [var.name]
}

run "domain_uppercase" {
  command = plan

  variables {
    domain = "SVP.example"
  }

  expect_failures = [var.domain]
}

run "hosted_zone_id_with_prefix" {
  command = plan

  variables {
    hosted_zone_id = "/hostedzone/Z0123456789ABCDEFGHIJ"
  }

  expect_failures = [var.hosted_zone_id]
}

run "vpc_id_malformed" {
  command = plan

  variables {
    vpc_id = "vpc_0123"
  }

  expect_failures = [var.vpc_id]
}

run "subnet_ids_single" {
  command = plan

  variables {
    subnet_ids = ["subnet-0123456789abcdef0"]
  }

  expect_failures = [var.subnet_ids]
}

run "node_security_group_id_malformed" {
  command = plan

  variables {
    node_security_group_id = "sg_0123"
  }

  expect_failures = [var.node_security_group_id]
}

run "web_acl_arns_missing_api" {
  command = plan

  variables {
    web_acl_arns = {
      web = "arn:aws:wafv2:us-east-1:000000000000:global/webacl/svp-stg-web/a1b2c3d4-5678-90ab-cdef-111111111111"
    }
  }

  expect_failures = [var.web_acl_arns]
}

run "web_acl_arns_regional" {
  command = plan

  variables {
    web_acl_arns = {
      web = "arn:aws:wafv2:us-east-1:000000000000:global/webacl/svp-stg-web/a1b2c3d4-5678-90ab-cdef-111111111111"
      api = "arn:aws:wafv2:ap-southeast-1:000000000000:regional/webacl/svp-stg-api/a1b2c3d4-5678-90ab-cdef-222222222222"
    }
  }

  expect_failures = [var.web_acl_arns]
}

run "log_delivery_destination_arn_bucket" {
  command = plan

  variables {
    log_delivery_destination_arn = "arn:aws:s3:::svp-cloudfront-111111111111-us-east-1"
  }

  expect_failures = [var.log_delivery_destination_arn]
}
