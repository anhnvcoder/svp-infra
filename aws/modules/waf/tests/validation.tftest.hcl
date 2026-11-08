# Validation rules of the module's variables: one plan per rule with a value that only that rule rejects; then the web
# ACL with the defaults and with the values of prd. The AWS provider is a mock: nothing reaches an account; the module
# reads no data source.

mock_provider "aws" {}

variables {
  name = "svp-stg-media"
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-media"
  }

  expect_failures = [var.name]
}

run "rate_limit_below_minimum" {
  command = plan

  variables {
    rate_limit = 5
  }

  expect_failures = [var.rate_limit]
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_wafv2_web_acl.this.scope == "CLOUDFRONT" && length(aws_wafv2_web_acl.this.default_action[0].allow) == 1
    error_message = "The web ACL must be of scope CLOUDFRONT and allow what no rule blocks."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.this.rule : r.statement[0].rate_based_statement[0].limit if r.name == "rate-limit-per-ip"]) == 2000
    error_message = "The default rate limit must be 2000 requests per IP in 5 minutes."
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this.rule) <= 5
    error_message = "The web ACL may hold at most 5 rules, the limit of the CloudFront flat-rate Free plan; counting each AWS managed rule group as one rule is an assumption, checked on the first session."
  }
}

# Values of the prd root: the rules that cut a flood and known attacks at the edge.
run "prd_values" {
  command = plan

  variables {
    name       = "svp-prd-media"
    rate_limit = 2000
  }

  assert {
    condition     = aws_wafv2_web_acl.this.name == "svp-prd-media" && aws_wafv2_web_acl.this.scope == "CLOUDFRONT"
    error_message = "prd must get a web ACL of scope CLOUDFRONT named after the env."
  }

  assert {
    condition = one([for r in aws_wafv2_web_acl.this.rule : r if r.name == "rate-limit-per-ip" &&
      r.priority == 0 &&
      length(r.action[0].block) == 1 &&
      r.statement[0].rate_based_statement[0].aggregate_key_type == "IP" &&
    r.statement[0].rate_based_statement[0].evaluation_window_sec == 300]) != null
    error_message = "prd must block a client IP over the rate limit, before any other rule."
  }

  assert {
    condition = toset([for r in aws_wafv2_web_acl.this.rule : r.statement[0].managed_rule_group_statement[0].name if length(r.statement[0].managed_rule_group_statement) > 0 && length(r.override_action[0].none) == 1]) == toset([
      "AWSManagedRulesCommonRuleSet",
      "AWSManagedRulesKnownBadInputsRuleSet",
    ])
    error_message = "prd must run both AWS managed rule groups with their own block actions."
  }
}
