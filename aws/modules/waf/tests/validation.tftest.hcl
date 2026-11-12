# Validation rules of the module's variables: one plan per rule with a value that only that rule rejects; then the web
# ACL with the defaults (the media ACL), with the values of the api and web ACLs, and its log. The AWS provider is a
# mock: nothing reaches an account; the module reads no data source.

mock_provider "aws" {}

variables {
  name           = "svp-stg-media"
  log_bucket_arn = "arn:aws:s3:::aws-waf-logs-svp-000000000000-us-east-1"
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

run "log_bucket_without_waf_prefix" {
  command = plan

  variables {
    log_bucket_arn = "arn:aws:s3:::svp-flowlogs-000000000000-ap-southeast-1"
  }

  expect_failures = [var.log_bucket_arn]
}

run "log_destination_not_s3" {
  command = plan

  variables {
    log_bucket_arn = "arn:aws:logs:us-east-1:000000000000:log-group:aws-waf-logs-svp"
  }

  expect_failures = [var.log_bucket_arn]
}

run "common_override_unknown_rule" {
  command = plan

  variables {
    common_rule_set_count_overrides = ["SizeRestriction_BODY"]
  }

  expect_failures = [var.common_rule_set_count_overrides]
}

run "common_override_repeated" {
  command = plan

  variables {
    common_rule_set_count_overrides = ["SizeRestrictions_BODY", "SizeRestrictions_BODY"]
  }

  expect_failures = [var.common_rule_set_count_overrides]
}

run "bot_control_targeted" {
  command = plan

  variables {
    bot_control = { inspection_level = "TARGETED" }
  }

  expect_failures = [var.bot_control]
}

run "atp_login_path_relative" {
  command = plan

  variables {
    atp = {
      login_path           = "auth/login"
      payload_type         = "JSON"
      username_field       = "/email"
      password_field       = "/password"
      success_status_codes = [200]
      failure_status_codes = [401]
    }
  }

  expect_failures = [var.atp]
}

run "atp_payload_multipart" {
  command = plan

  variables {
    atp = {
      login_path           = "/auth/login"
      payload_type         = "MULTIPART"
      username_field       = "/email"
      password_field       = "/password"
      success_status_codes = [200]
      failure_status_codes = [401]
    }
  }

  expect_failures = [var.atp]
}

run "atp_json_field_not_pointer" {
  command = plan

  variables {
    atp = {
      login_path           = "/auth/login"
      payload_type         = "JSON"
      username_field       = "email"
      password_field       = "/password"
      success_status_codes = [200]
      failure_status_codes = [401]
    }
  }

  expect_failures = [var.atp]
}

run "atp_form_field_pointer" {
  command = plan

  variables {
    atp = {
      login_path           = "/auth/login"
      payload_type         = "FORM_ENCODED"
      username_field       = "email"
      password_field       = "/password"
      success_status_codes = [200]
      failure_status_codes = [401]
    }
  }

  expect_failures = [var.atp]
}

run "atp_status_code_in_both" {
  command = plan

  variables {
    atp = {
      login_path           = "/auth/login"
      payload_type         = "JSON"
      username_field       = "/email"
      password_field       = "/password"
      success_status_codes = [200]
      failure_status_codes = [401, 200]
    }
  }

  expect_failures = [var.atp]
}

run "atp_status_code_out_of_range" {
  command = plan

  variables {
    atp = {
      login_path           = "/auth/login"
      payload_type         = "JSON"
      username_field       = "/email"
      password_field       = "/password"
      success_status_codes = [200]
      failure_status_codes = [4010]
    }
  }

  expect_failures = [var.atp]
}

run "atp_no_failure_code" {
  command = plan

  variables {
    atp = {
      login_path           = "/auth/login"
      payload_type         = "JSON"
      username_field       = "/email"
      password_field       = "/password"
      success_status_codes = [200]
      failure_status_codes = []
    }
  }

  expect_failures = [var.atp]
}

# The defaults are the media web ACL: 4 rules, within the 5 of the CloudFront flat-rate Free plan of stg media.
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
    condition     = length(aws_wafv2_web_acl.this.rule) == 4
    error_message = "The default web ACL must hold exactly 4 rules, within the 5 of the CloudFront flat-rate Free plan."
  }

  assert {
    condition = { for r in aws_wafv2_web_acl.this.rule : r.priority => (
      length(r.statement[0].managed_rule_group_statement) > 0 ? r.statement[0].managed_rule_group_statement[0].name : r.name
      ) } == {
      0 = "rate-limit-per-ip"
      1 = "AWSManagedRulesAmazonIpReputationList"
      2 = "AWSManagedRulesCommonRuleSet"
      3 = "AWSManagedRulesKnownBadInputsRuleSet"
    }
    error_message = "The rules must run in this order: rate limit per IP, IP reputation, common rule set, known bad inputs."
  }

  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.this.rule : length(r.override_action[0].none) == 1 &&
      length(r.statement[0].managed_rule_group_statement[0].rule_action_override) == 0 &&
    length(r.statement[0].managed_rule_group_statement[0].managed_rule_group_configs) == 0 if r.priority > 0])
    error_message = "Every managed rule group must keep its own actions, without override or configuration, by default."
  }
}

# Values of the prd root for media: the rules that cut a flood and known attacks at the edge.
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
      "AWSManagedRulesAmazonIpReputationList",
      "AWSManagedRulesCommonRuleSet",
      "AWSManagedRulesKnownBadInputsRuleSet",
    ])
    error_message = "prd must run the three AWS managed rule groups with their own block actions."
  }
}

# The api web ACL: account takeover prevention on POST /auth/login of the gateway, after every other rule.
run "api_atp" {
  command = plan

  variables {
    name = "svp-stg-api"
    atp = {
      login_path           = "/auth/login"
      payload_type         = "JSON"
      username_field       = "/email"
      password_field       = "/password"
      success_status_codes = [200]
      failure_status_codes = [401]
    }
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this.rule) == 5
    error_message = "The api web ACL must hold the 4 default rules plus ATP."
  }

  assert {
    condition = one([for r in aws_wafv2_web_acl.this.rule : r if r.name == "aws-atp" && r.priority == 4 &&
      length(r.override_action[0].none) == 1 &&
    r.statement[0].managed_rule_group_statement[0].name == "AWSManagedRulesATPRuleSet"]) != null
    error_message = "ATP must be the last rule (priority 4) and keep the group's own actions."
  }

  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.this.rule : alltrue([for c in [r.statement[0].managed_rule_group_statement[0].managed_rule_group_configs[0].aws_managed_rules_atp_rule_set[0]] :
      c.login_path == "/auth/login" &&
      c.request_inspection[0].payload_type == "JSON" &&
      c.request_inspection[0].username_field[0].identifier == "/email" &&
      c.request_inspection[0].password_field[0].identifier == "/password" &&
      c.response_inspection[0].status_code[0].success_codes == toset([200]) &&
    c.response_inspection[0].status_code[0].failure_codes == toset([401])]) if r.name == "aws-atp"])
    error_message = "ATP must inspect the JSON fields /email and /password on /auth/login and read 200 as success, 401 as failure."
  }

  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.this.rule : alltrue([for m in [r.statement[0].managed_rule_group_statement[0].scope_down_statement[0].byte_match_statement[0]] :
      m.search_string == "/auth/login" &&
      m.positional_constraint == "EXACTLY" &&
      length(m.field_to_match[0].uri_path) == 1 &&
    [for t in m.text_transformation : t.type] == ["NONE"]]) if r.name == "aws-atp"])
    error_message = "ATP must be scoped down to the URI path that is exactly the login path, untransformed."
  }

  assert {
    condition     = length([for r in aws_wafv2_web_acl.this.rule : r if r.name == "aws-bot-control"]) == 0
    error_message = "The api web ACL must not run Bot Control."
  }
}

# The web web ACL: Bot Control at COMMON labels only, and SizeRestrictions_BODY counts for the browser error reports.
run "web_bot_control" {
  command = plan

  variables {
    name                            = "svp-stg-web"
    bot_control                     = { inspection_level = "COMMON" }
    common_rule_set_count_overrides = ["SizeRestrictions_BODY"]
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this.rule) == 5
    error_message = "The web web ACL must hold the 4 default rules plus Bot Control."
  }

  assert {
    condition = one([for r in aws_wafv2_web_acl.this.rule : r if r.name == "aws-bot-control" && r.priority == 4 &&
      length(r.override_action[0].count) == 1 &&
      r.statement[0].managed_rule_group_statement[0].name == "AWSManagedRulesBotControlRuleSet" &&
    r.statement[0].managed_rule_group_statement[0].managed_rule_group_configs[0].aws_managed_rules_bot_control_rule_set[0].inspection_level == "COMMON"]) != null
    error_message = "Bot Control must be the last rule (priority 4), at level COMMON, with the whole group overridden to count."
  }

  assert {
    condition = alltrue(flatten([for r in aws_wafv2_web_acl.this.rule : [for o in r.statement[0].managed_rule_group_statement[0].rule_action_override :
      length(o.action_to_use[0].count) == 1 && length(o.action_to_use[0].block) == 0] if r.name == "aws-bot-control"])) && toset(flatten([for r in aws_wafv2_web_acl.this.rule : [for o in r.statement[0].managed_rule_group_statement[0].rule_action_override : o.name] if r.name == "aws-bot-control"])) == toset([
      "CategoryAdvertising", "CategoryAI", "CategoryArchiver", "CategoryContentFetcher", "CategoryEmailClient",
      "CategoryHttpLibrary", "CategoryLinkChecker", "CategoryMiscellaneous", "CategoryMonitoring", "CategoryPagePreview",
      "CategoryScrapingFramework", "CategorySearchEngine", "CategorySecurity", "CategorySeo", "CategorySocialMedia",
      "CategoryWebhooks", "SignalAutomatedBrowser", "SignalKnownBotDataCenter", "SignalNonBrowserUserAgent",
    ])
    error_message = "Every rule of Bot Control's COMMON level must be overridden to count, so that every rule runs and labels."
  }

  assert {
    condition = one([for r in aws_wafv2_web_acl.this.rule : [for o in r.statement[0].managed_rule_group_statement[0].rule_action_override :
    { name = o.name, count = length(o.action_to_use[0].count) }] if r.name == "aws-common"]) == [{ name = "SizeRestrictions_BODY", count = 1 }]
    error_message = "The common rule set must count SizeRestrictions_BODY and keep every other rule's action."
  }

  assert {
    condition     = length([for r in aws_wafv2_web_acl.this.rule : r if r.name == "aws-atp"]) == 0
    error_message = "The web web ACL must not run ATP."
  }
}

# Both optional groups together: Bot Control before ATP, priorities unique.
run "bot_control_and_atp" {
  command = plan

  variables {
    bot_control = { inspection_level = "COMMON" }
    atp = {
      login_path           = "/login"
      payload_type         = "FORM_ENCODED"
      username_field       = "email"
      password_field       = "password"
      success_status_codes = [200, 303]
      failure_status_codes = [401]
    }
  }

  assert {
    condition = { for r in aws_wafv2_web_acl.this.rule : r.name => r.priority if r.priority >= 4 } == {
      aws-bot-control = 4
      aws-atp         = 5
    }
    error_message = "With both groups, Bot Control must run at priority 4 and ATP at 5."
  }
}

# Every request of the web ACL goes to the WAF log bucket of the Log Archive account, without credentials or cookies.
run "logging" {
  command = plan

  assert {
    condition     = aws_wafv2_web_acl_logging_configuration.this.log_destination_configs == toset(["arn:aws:s3:::aws-waf-logs-svp-000000000000-us-east-1"])
    error_message = "The web ACL must log to the bucket of log_bucket_arn and nowhere else."
  }

  assert {
    condition = toset([for f in aws_wafv2_web_acl_logging_configuration.this.redacted_fields : f.single_header[0].name if length(f.single_header) > 0]) == toset([
      "authorization",
      "cookie",
    ]) && length(aws_wafv2_web_acl_logging_configuration.this.redacted_fields) == 2
    error_message = "The log must redact exactly the authorization and cookie headers."
  }

  assert {
    condition     = length(aws_wafv2_web_acl_logging_configuration.this.logging_filter) == 0
    error_message = "The log must keep every request, with no logging filter."
  }
}
