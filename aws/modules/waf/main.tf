# An AWS WAF web ACL for a CloudFront distribution. Scope CLOUDFRONT: AWS accepts such a web ACL only in us-east-1, so
# the root calls this module with a provider of that region (providers = { aws = aws.us_east_1 }) and passes
# web_acl_arn to the distribution. Requests that no rule blocks are allowed. The rate-based rule per client IP is
# first, so a flood is cut before the managed rules are billed for it.

# Design notes: aws/modules/waf/README.md.

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = "Edge protection of ${var.name}: rate limit per IP and AWS managed rule groups"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 1

    # none: the group's own actions (block) apply, rather than being turned into count.
    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-aws-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-aws-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }

  tags = {
    Name = var.name
  }
}
