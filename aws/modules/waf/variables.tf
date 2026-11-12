variable "name" {
  description = "Name of the web ACL and prefix of the CloudWatch metric names of its rules, e.g. svp-prd-media."
  type        = string

  validation {
    # The rules of a WAF name; metric names (the name plus a suffix of at most 15 characters) have the same alphabet.
    condition     = can(regex("^[a-z][a-z0-9-]{1,100}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 102 lowercase letters, digits or hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "rate_limit" {
  description = "Requests one client IP address may send within 5 minutes before the web ACL blocks it, until its rate falls back under the limit. A viewer of HLS fetches a segment every few seconds, a few hundred requests in 5 minutes; the default leaves room for several viewers behind one address."
  type        = number
  default     = 2000

  validation {
    condition     = var.rate_limit >= 10 && var.rate_limit <= 2000000000 && floor(var.rate_limit) == var.rate_limit
    error_message = "rate_limit must be a whole number from 10 to 2000000000."
  }
}

variable "log_bucket_arn" {
  description = "ARN of the S3 bucket that receives the web ACL's logs: the WAF log bucket of the Log Archive account, arn:aws:s3:::aws-waf-logs-svp-<log account>-us-east-1."
  type        = string
  nullable    = false

  validation {
    # WAF delivers to S3 only into a bucket whose name starts with aws-waf-logs-.
    condition     = can(regex("^arn:aws[a-z-]*:s3:::aws-waf-logs-[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.log_bucket_arn))
    error_message = "log_bucket_arn must be the ARN of an S3 bucket whose name starts with aws-waf-logs-, e.g. arn:aws:s3:::aws-waf-logs-svp-000000000000-us-east-1."
  }
}

variable "common_rule_set_count_overrides" {
  description = "Rules of AWSManagedRulesCommonRuleSet that only count instead of blocking, for a rule that blocks a legitimate flow of this distribution (e.g. SizeRestrictions_BODY where bodies exceed 8 KB). Empty: every rule of the group keeps its own action."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    # AWS ignores an override whose rule name it does not know, so a typo would silently leave the rule blocking.
    condition = alltrue([for r in var.common_rule_set_count_overrides : contains([
      "NoUserAgent_HEADER", "UserAgent_BadBots_HEADER",
      "SizeRestrictions_QUERYSTRING", "SizeRestrictions_Cookie_HEADER", "SizeRestrictions_BODY", "SizeRestrictions_URIPATH",
      "EC2MetaDataSSRF_BODY", "EC2MetaDataSSRF_COOKIE", "EC2MetaDataSSRF_URIPATH", "EC2MetaDataSSRF_QUERYARGUMENTS",
      "GenericLFI_QUERYARGUMENTS", "GenericLFI_URIPATH", "GenericLFI_BODY",
      "RestrictedExtensions_URIPATH", "RestrictedExtensions_QUERYARGUMENTS",
      "GenericRFI_QUERYARGUMENTS", "GenericRFI_BODY", "GenericRFI_URIPATH",
      "CrossSiteScripting_COOKIE", "CrossSiteScripting_QUERYARGUMENTS", "CrossSiteScripting_BODY", "CrossSiteScripting_URIPATH",
    ], r)]) && length(distinct(var.common_rule_set_count_overrides)) == length(var.common_rule_set_count_overrides)
    error_message = "common_rule_set_count_overrides must name distinct rules of AWSManagedRulesCommonRuleSet, e.g. SizeRestrictions_BODY."
  }
}

variable "bot_control" {
  description = "Bot Control (AWSManagedRulesBotControlRuleSet) at this inspection level, after the other rules: the whole group and each of its rules only count, so it labels bots in the WAF log and blocks nothing. null: no Bot Control."
  type = object({
    inspection_level = string
  })
  default = null

  validation {
    # The module overrides the rules of the COMMON level; TARGETED adds rules that this list does not cover.
    condition     = var.bot_control == null || try(var.bot_control.inspection_level == "COMMON", false)
    error_message = "bot_control.inspection_level must be COMMON."
  }
}

variable "atp" {
  description = "Account takeover prevention (AWSManagedRulesATPRuleSet) for the login endpoint, last rule of the web ACL, scoped down to requests whose URI path is exactly login_path: payload_type JSON or FORM_ENCODED, username_field and password_field as JSON pointers (JSON) or form field names, and the response status codes of a successful and a failed login. null: no ATP."
  type = object({
    login_path           = string
    payload_type         = string
    username_field       = string
    password_field       = string
    success_status_codes = list(number)
    failure_status_codes = list(number)
  })
  default = null

  validation {
    condition     = var.atp == null || try(can(regex("^/[^[:space:]]*$", var.atp.login_path)), false)
    error_message = "atp.login_path must be a URI path starting with /, without whitespace, e.g. /auth/login."
  }

  validation {
    condition     = var.atp == null || try(contains(["JSON", "FORM_ENCODED"], var.atp.payload_type), false)
    error_message = "atp.payload_type must be JSON or FORM_ENCODED."
  }

  validation {
    # A JSON field is named by a JSON pointer; a form field by its name.
    condition = var.atp == null || try(alltrue([for f in [var.atp.username_field, var.atp.password_field] :
    var.atp.payload_type == "JSON" ? can(regex("^/[^[:space:]]+$", f)) : can(regex("^[^/[:space:]][^[:space:]]*$", f))]), false)
    error_message = "atp.username_field and atp.password_field must be JSON pointers such as /email when payload_type is JSON, or form field names such as email when it is FORM_ENCODED."
  }

  validation {
    condition = var.atp == null || try(
      length(var.atp.success_status_codes) > 0 && length(var.atp.failure_status_codes) > 0 &&
      alltrue([for c in concat(var.atp.success_status_codes, var.atp.failure_status_codes) : c >= 100 && c <= 599 && floor(c) == c]) &&
      length(setintersection(var.atp.success_status_codes, var.atp.failure_status_codes)) == 0,
    false)
    error_message = "atp.success_status_codes and atp.failure_status_codes must each hold at least one HTTP status code (100 to 599), and no code may be in both."
  }
}
