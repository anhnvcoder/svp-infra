# An AWS WAF web ACL for a CloudFront distribution. Scope CLOUDFRONT: AWS accepts such a web ACL only in us-east-1, so
# the root calls this module with a provider of that region (providers = { aws = aws.us_east_1 }) and passes
# web_acl_arn to the distribution. Requests that no rule blocks are allowed. Rules run cheapest first: the rate limit
# per IP, IP reputation, the baseline groups, then Bot Control and account takeover prevention when set.

# Design notes: aws/modules/waf/README.md.

locals {
  # Every rule of Bot Control's COMMON level. Each is overridden to count so that all of them run and label requests;
  # AWS ignores an override whose rule name it does not know rather than failing the apply.
  bot_control_common_rules = [
    "CategoryAdvertising",
    "CategoryAI",
    "CategoryArchiver",
    "CategoryContentFetcher",
    "CategoryEmailClient",
    "CategoryHttpLibrary",
    "CategoryLinkChecker",
    "CategoryMiscellaneous",
    "CategoryMonitoring",
    "CategoryPagePreview",
    "CategoryScrapingFramework",
    "CategorySearchEngine",
    "CategorySecurity",
    "CategorySeo",
    "CategorySocialMedia",
    "CategoryWebhooks",
    "SignalAutomatedBrowser",
    "SignalKnownBotDataCenter",
    "SignalNonBrowserUserAgent",
  ]

  atp_priority = var.bot_control == null ? 4 : 5
}

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
    name     = "aws-ip-reputation"
    priority = 1

    # none: the group's own actions apply, rather than being turned into count.
    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-aws-ip-rep"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        dynamic "rule_action_override" {
          for_each = var.common_rule_set_count_overrides

          content {
            name = rule_action_override.value

            action_to_use {
              count {}
            }
          }
        }
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
    priority = 3

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

  # Labels only, until bot traffic has been measured: the group's count stops any rule AWS adds later from blocking,
  # and the count of each rule lets every rule run instead of stopping at the first match.
  dynamic "rule" {
    for_each = var.bot_control == null ? [] : [var.bot_control]

    content {
      name     = "aws-bot-control"
      priority = 4

      override_action {
        count {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = "AWSManagedRulesBotControlRuleSet"

          managed_rule_group_configs {
            aws_managed_rules_bot_control_rule_set {
              inspection_level = rule.value.inspection_level
              # Machine learning feeds only rules of the TARGETED level; set rather than left to the value AWS picks.
              enable_machine_learning = false
            }
          }

          dynamic "rule_action_override" {
            for_each = local.bot_control_common_rules

            content {
              name = rule_action_override.value

              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-aws-bot"
        sampled_requests_enabled   = true
      }
    }
  }

  # Account takeover prevention is billed per request it inspects, so the scope-down keeps it to the login path.
  dynamic "rule" {
    for_each = var.atp == null ? [] : [var.atp]

    content {
      name     = "aws-atp"
      priority = local.atp_priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = "AWSManagedRulesATPRuleSet"

          managed_rule_group_configs {
            aws_managed_rules_atp_rule_set {
              login_path           = rule.value.login_path
              enable_regex_in_path = false

              request_inspection {
                payload_type = rule.value.payload_type

                username_field {
                  identifier = rule.value.username_field
                }

                password_field {
                  identifier = rule.value.password_field
                }
              }

              response_inspection {
                status_code {
                  success_codes = rule.value.success_status_codes
                  failure_codes = rule.value.failure_status_codes
                }
              }
            }
          }

          scope_down_statement {
            byte_match_statement {
              search_string         = rule.value.login_path
              positional_constraint = "EXACTLY"

              field_to_match {
                uri_path {}
              }

              text_transformation {
                priority = 0
                type     = "NONE"
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-aws-atp"
        sampled_requests_enabled   = true
      }
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

# Every request goes to the WAF log bucket of the Log Archive account; that bucket's policy lets the log delivery
# service write for accounts of the organization, so this account needs no bucket policy rights. Credentials and
# session cookies stay out of the log.
resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [var.log_bucket_arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}
