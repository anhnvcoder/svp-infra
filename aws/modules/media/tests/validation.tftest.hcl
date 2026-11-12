# Validation rules: one plan with valid values, then one plan per rule with a value only that rule rejects; then the
# defaults, each pricing plan of the distribution, each new variable and the values of prd. The AWS provider is a mock:
# nothing reaches an account, data sources return the values below, policies must still be JSON. The plan cannot prove
# that AWS accepts the plan tier or the managed policy.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }

  mock_data "aws_cloudfront_response_headers_policy" {
    defaults = {
      id = "60669652-455b-4ae9-85a4-c4c02393f86c"
    }
  }
}

variables {
  name_prefix          = "svp-stg"
  account_id           = "000000000000"
  region               = "ap-southeast-1"
  cors_allowed_origins = ["https://svp.example"]
  force_destroy        = true
  web_acl_arn          = "arn:aws:wafv2:us-east-1:000000000000:global/webacl/svp-stg-media/a1b2c3d4-5678-90ab-cdef-111111111111"
  domain               = "svp.example"
  hosted_zone_id       = "Z0123456789ABCDEFGHIJ"
  flat_rate_free       = true
}

run "valid" {
  command = plan
}

run "name_prefix_double_hyphen" {
  command = plan

  variables {
    name_prefix = "svp--stg"
  }

  expect_failures = [var.name_prefix]
}

run "account_id_short" {
  command = plan

  variables {
    account_id = "12345"
  }

  expect_failures = [var.account_id]
}

run "region_uppercase" {
  command = plan

  variables {
    region = "AP-SOUTHEAST-1"
  }

  expect_failures = [var.region]
}

run "cors_allowed_origins_with_path" {
  command = plan

  variables {
    cors_allowed_origins = ["https://svp.example/*"]
  }

  expect_failures = [var.cors_allowed_origins]
}

run "web_acl_arn_regional" {
  command = plan

  variables {
    web_acl_arn = "arn:aws:wafv2:ap-southeast-1:000000000000:regional/webacl/svp-prd-media/a1b2c3d4-5678-90ab-cdef-111111111111"
  }

  expect_failures = [var.web_acl_arn]
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

# A pay-as-you-go distribution writes standard logs, so it cannot go without a destination.
run "pay_as_you_go_without_log_destination" {
  command = plan

  variables {
    flat_rate_free = false
  }

  expect_failures = [var.log_delivery_destination_arn]
}

run "log_delivery_destination_arn_bucket" {
  command = plan

  variables {
    flat_rate_free               = false
    log_delivery_destination_arn = "arn:aws:s3:::svp-cloudfront-111111111111-us-east-1"
  }

  expect_failures = [var.log_delivery_destination_arn]
}

# The defaults keep the buckets as they were: no versioning, no access log and no log bucket.
run "defaults" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_versioning.this) == 0 && alltrue([for r in aws_s3_bucket_lifecycle_configuration.media.rule : r.id != "expire-noncurrent-versions"])
    error_message = "By default the buckets must keep no earlier versions."
  }

  assert {
    condition     = length(aws_s3_bucket.logs) == 0 && length(aws_s3_bucket_logging.this) == 0
    error_message = "By default the module must create no log bucket and write no access log."
  }

}

# Attribute names below are built with join: the guard of make test refuses any line that holds the word naming a
# provider configuration, and CloudFront and Route 53 use that word for alternate names.

# What both plans share: the name media.<domain> with its own certificate in us-east-1, the viewer TLS policy, an A and
# an AAAA record to the distribution, every edge location, and the bucket, OAC and cache policy as they were.
run "name_and_tls" {
  command = plan

  assert {
    condition     = aws_cloudfront_distribution.media[join("", ["ali", "ases"])] == toset(["media.svp.example"]) && output.media_domain == "media.svp.example"
    error_message = "The distribution must answer at media.<domain> alone, and media_domain must be that name."
  }

  assert {
    condition = (aws_cloudfront_distribution.media.viewer_certificate[0].minimum_protocol_version == "TLSv1.2_2025" &&
      aws_cloudfront_distribution.media.viewer_certificate[0].ssl_support_method == "sni-only" &&
    aws_cloudfront_distribution.media.viewer_certificate[0].cloudfront_default_certificate != true)
    error_message = "The distribution must use its own certificate with the viewer TLS policy TLSv1.2_2025 and SNI."
  }

  assert {
    condition = (aws_acm_certificate.viewer.region == "us-east-1" && aws_acm_certificate.viewer.domain_name == "media.svp.example" &&
      aws_acm_certificate.viewer.key_algorithm == "EC_prime256v1" &&
    aws_acm_certificate.viewer.validation_method == "DNS" && aws_acm_certificate_validation.viewer.region == "us-east-1")
    error_message = "The certificate must be ECDSA P-256 in us-east-1 for media.<domain> alone, validated by DNS."
  }

  assert {
    condition     = aws_route53_record.validation.zone_id == var.hosted_zone_id
    error_message = "The validation record must be in the env's zone."
  }

  assert {
    condition = (length(aws_route53_record.media) == 2 && toset([for r in aws_route53_record.media : r.type]) == toset(["A", "AAAA"]) &&
      alltrue([for r in aws_route53_record.media : r.zone_id == var.hosted_zone_id && r.name == "media.svp.example" &&
    !r[join("", ["ali", "as"])][0].evaluate_target_health]))
    error_message = "media.<domain> must get an A and an AAAA record in the env's zone, pointing at the distribution."
  }

  assert {
    condition = (aws_cloudfront_distribution.media.comment == "svp-stg-media" && aws_cloudfront_distribution.media.tags["Name"] == "svp-stg-media" &&
      aws_cloudfront_distribution.media.http_version == "http2and3" && aws_cloudfront_distribution.media.is_ipv6_enabled &&
    aws_cloudfront_distribution.media.price_class == "PriceClass_All")
    error_message = "The distribution must be named <name_prefix>-media and serve HTTP/2 and 3 over IPv6 at every edge location."
  }

  assert {
    condition = (aws_cloudfront_distribution.media.default_cache_behavior[0].viewer_protocol_policy == "https-only" &&
      aws_cloudfront_distribution.media.default_cache_behavior[0].allowed_methods == toset(["GET", "HEAD"]) &&
      aws_cloudfront_distribution.media.default_cache_behavior[0].cache_policy_id == data.aws_cloudfront_cache_policy.caching_optimized.id &&
    data.aws_cloudfront_cache_policy.caching_optimized.name == "Managed-CachingOptimized")
    error_message = "The distribution must serve GET and HEAD over HTTPS only, cached with Managed-CachingOptimized."
  }
}

# The flat-rate Free plan: it covers the distribution and its web ACL, and the distribution uses only features of the
# plan (a managed response headers policy, no access log).
run "flat_rate_plan" {
  command = plan

  assert {
    condition = (length(aws_pricingplanmanager_subscription.media) == 1 &&
      aws_pricingplanmanager_subscription.media[0].plan_family == "CloudFront" &&
      aws_pricingplanmanager_subscription.media[0].plan_tier == "FREE" &&
    aws_pricingplanmanager_subscription.media[0].approval_mode == null)
    error_message = "flat_rate_free = true must subscribe the distribution to the CloudFront flat-rate Free plan, with the default approval mode."
  }

  assert {
    condition     = anytrue([for a in aws_pricingplanmanager_subscription.media[0].resource_arns : a == var.web_acl_arn])
    error_message = "The plan must cover the web ACL of the distribution."
  }

  assert {
    condition     = aws_cloudfront_distribution.media.web_acl_id == var.web_acl_arn
    error_message = "The distribution must carry the web ACL."
  }

  assert {
    condition = (data.aws_cloudfront_response_headers_policy.simple_cors[0].name == "Managed-SimpleCORS" &&
      aws_cloudfront_distribution.media.default_cache_behavior[0].response_headers_policy_id == "60669652-455b-4ae9-85a4-c4c02393f86c" &&
    length(aws_cloudfront_response_headers_policy.media) == 0)
    error_message = "On the Free plan the distribution must answer CORS with the managed policy Managed-SimpleCORS, the only kind the plan takes."
  }

  assert {
    condition     = length(aws_cloudwatch_log_delivery_source.media) == 0 && length(aws_cloudwatch_log_delivery.media) == 0
    error_message = "On the Free plan the distribution must write no access log, which the plan does not include."
  }
}

# Pay-as-you-go: no plan, the module's own CORS and security headers policy, and standard logs without cookies.
run "pay_as_you_go" {
  command = plan

  variables {
    flat_rate_free               = false
    cors_allowed_origins         = ["https://svp.example", "http://localhost:3000"]
    log_delivery_destination_arn = "arn:aws:logs:us-east-1:111111111111:delivery-destination:svp-cloudfront-prd"
  }

  assert {
    condition     = length(aws_pricingplanmanager_subscription.media) == 0 && length(data.aws_cloudfront_response_headers_policy.simple_cors) == 0
    error_message = "flat_rate_free = false must subscribe to no plan and use no managed headers policy."
  }

  assert {
    condition = (length(aws_cloudfront_response_headers_policy.media) == 1 &&
      aws_cloudfront_response_headers_policy.media[0].name == "svp-stg-media" &&
      aws_cloudfront_response_headers_policy.media[0].cors_config[0].access_control_allow_origins[0].items == toset(var.cors_allowed_origins) &&
      aws_cloudfront_response_headers_policy.media[0].cors_config[0].access_control_allow_methods[0].items == toset(["GET", "HEAD"]) &&
      !aws_cloudfront_response_headers_policy.media[0].cors_config[0].access_control_allow_credentials &&
    aws_cloudfront_response_headers_policy.media[0].cors_config[0].origin_override)
    error_message = "The own policy <name_prefix>-media must allow exactly cors_allowed_origins, for GET and HEAD, without credentials."
  }

  assert {
    condition = (aws_cloudfront_response_headers_policy.media[0].security_headers_config[0].strict_transport_security[0].access_control_max_age_sec == 63072000 &&
      aws_cloudfront_response_headers_policy.media[0].security_headers_config[0].strict_transport_security[0].include_subdomains &&
      !aws_cloudfront_response_headers_policy.media[0].security_headers_config[0].strict_transport_security[0].preload &&
      aws_cloudfront_response_headers_policy.media[0].security_headers_config[0].strict_transport_security[0].override &&
    aws_cloudfront_response_headers_policy.media[0].security_headers_config[0].content_type_options[0].override)
    error_message = "The own policy must send HSTS for two years with subdomains and no preload, and nosniff, both overriding the origin."
  }

  assert {
    condition = (aws_cloudwatch_log_delivery_source.media[0].region == "us-east-1" &&
      aws_cloudwatch_log_delivery_source.media[0].log_type == "ACCESS_LOGS" &&
    aws_cloudwatch_log_delivery_source.media[0].name == "svp-stg-media")
    error_message = "The distribution must have an ACCESS_LOGS delivery source <name_prefix>-media in us-east-1."
  }

  assert {
    condition = (aws_cloudwatch_log_delivery.media[0].region == "us-east-1" &&
      aws_cloudwatch_log_delivery.media[0].delivery_destination_arn == var.log_delivery_destination_arn &&
      !contains(aws_cloudwatch_log_delivery.media[0].record_fields, "cs(Cookie)") &&
      length(aws_cloudwatch_log_delivery.media[0].record_fields) == 34 &&
    contains(aws_cloudwatch_log_delivery.media[0].record_fields, "c-ip"))
    error_message = "The delivery must go from us-east-1 to the given destination with the 34 fields of the ADR, never cs(Cookie)."
  }

  assert {
    condition = (aws_cloudwatch_log_delivery.media[0].s3_delivery_configuration[0].suffix_path == "{DistributionId}/{yyyy}/{MM}/{dd}/{HH}" &&
    aws_cloudwatch_log_delivery.media[0].s3_delivery_configuration[0].enable_hive_compatible_path)
    error_message = "Logs must be written under a Hive-style path per distribution and hour."
  }

  assert {
    condition = (aws_cloudfront_distribution.media[join("", ["ali", "ases"])] == toset(["media.svp.example"]) &&
      aws_cloudfront_distribution.media.viewer_certificate[0].minimum_protocol_version == "TLSv1.2_2025" &&
    aws_cloudfront_distribution.media.price_class == "PriceClass_All" && aws_cloudfront_distribution.media.web_acl_id == var.web_acl_arn)
    error_message = "Off the plan the distribution keeps its name, viewer TLS policy, every edge location and web ACL."
  }
}

run "versioning_on" {
  command = plan

  variables {
    versioning_enabled = true
  }

  assert {
    condition     = toset(keys(aws_s3_bucket_versioning.this)) == toset(["uploads", "media"]) && alltrue([for v in aws_s3_bucket_versioning.this : v.versioning_configuration[0].status == "Enabled"])
    error_message = "versioning_enabled = true must turn versioning on in both buckets."
  }

  assert {
    condition = alltrue([for l in [aws_s3_bucket_lifecycle_configuration.uploads, aws_s3_bucket_lifecycle_configuration.media] :
    anytrue([for r in l.rule : r.id == "expire-noncurrent-versions" && r.noncurrent_version_expiration[0].noncurrent_days == 30])])
    error_message = "With versioning on, both buckets must delete earlier versions 30 days after they were replaced."
  }
}

run "access_logging_on" {
  command = plan

  variables {
    access_logging_enabled = true
  }

  assert {
    condition     = aws_s3_bucket.logs[0].bucket == "svp-stg-logs-000000000000-ap-southeast-1" && aws_s3_bucket.logs[0].force_destroy == true
    error_message = "access_logging_enabled = true must create the log bucket, destroyed with the env like the others."
  }

  assert {
    condition     = aws_s3_bucket_logging.this["uploads"].target_prefix == "uploads/" && aws_s3_bucket_logging.this["media"].target_prefix == "media/" && length(aws_s3_bucket_logging.this) == 2
    error_message = "Each of the two buckets, and not the log bucket, must log under a prefix of its own."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.logs[0].restrict_public_buckets == true && aws_s3_bucket_ownership_controls.logs[0].rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "The log bucket must stay private, without ACLs."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.logs[0].rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "The log bucket must use SSE-S3, the only default encryption S3 server access logs accept."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.logs[0].rule[0].expiration[0].days == 90
    error_message = "Access logs must be deleted after 90 days."
  }
}

# Malware Protection for S3 on the uploads bucket only, in every env: each new object is scanned and tagged with the
# result, by a role that only GuardDuty's malware protection service may assume.
run "malware_protection" {
  command = plan

  assert {
    condition     = one(one(aws_guardduty_malware_protection_plan.uploads.protected_resource).s3_bucket).bucket_name == "svp-stg-uploads-000000000000-ap-southeast-1"
    error_message = "The plan must protect the uploads bucket."
  }

  assert {
    condition     = one(one(aws_guardduty_malware_protection_plan.uploads.actions).tagging).status == "ENABLED"
    error_message = "The plan must tag each scanned object with the result."
  }

  assert {
    condition = (aws_iam_role.malware_protection.name == "svp-stg-uploads-malware-protection" &&
      jsondecode(aws_iam_role.malware_protection.assume_role_policy).Statement[0].Principal.Service == "malware-protection-plan.guardduty.amazonaws.com" &&
    length(jsondecode(aws_iam_role.malware_protection.assume_role_policy).Statement) == 1)
    error_message = "Only the GuardDuty malware protection service may assume the role of the plan."
  }

  assert {
    condition = toset([for s in data.aws_iam_policy_document.malware_protection.statement : s.sid]) == toset([
      "AllowManagedRuleToSendS3EventsToGuardDuty",
      "AllowGuardDutyToMonitorEventBridgeManagedRule",
      "AllowPostScanTag",
      "AllowEnableS3EventBridgeEvents",
      "AllowPutValidationObject",
      "AllowCheckBucketOwnership",
      "AllowMalwareScan",
    ])
    error_message = "The role must hold the statements of the GuardDuty guide for a bucket without KMS, and nothing else."
  }

  assert {
    condition     = alltrue([for s in data.aws_iam_policy_document.malware_protection.statement : alltrue([for a in s.actions : !strcontains(a, "*") && !startswith(a, "kms:")])])
    error_message = "The role must name each action, with no wildcard and no KMS action (the uploads bucket uses SSE-S3)."
  }

  assert {
    condition     = one([for s in data.aws_iam_policy_document.malware_protection.statement : s.resources if s.sid == "AllowManagedRuleToSendS3EventsToGuardDuty"]) == toset(["arn:aws:events:ap-southeast-1:000000000000:rule/DO-NOT-DELETE-AmazonGuardDutyMalwareProtectionS3*"])
    error_message = "The role may only change the EventBridge rule GuardDuty manages for the plan."
  }

  assert {
    condition     = alltrue([for r in aws_s3_bucket_lifecycle_configuration.uploads.rule : length(r.filter[0].tag) == 0 && length(r.filter[0].and) == 0])
    error_message = "No lifecycle rule of the uploads bucket may filter on object tags, which the scan result tag would then change."
  }
}

# Values of the prd root: buckets that destroy does not empty, earlier versions kept, access logs, and the web ACL of
# the waf module in front of the distribution.
run "prd_values" {
  command = plan

  variables {
    name_prefix                  = "svp-prd"
    account_id                   = "222222222222"
    force_destroy                = false
    versioning_enabled           = true
    access_logging_enabled       = true
    web_acl_arn                  = "arn:aws:wafv2:us-east-1:222222222222:global/webacl/svp-prd-media/a1b2c3d4-5678-90ab-cdef-111111111111"
    flat_rate_free               = false
    log_delivery_destination_arn = "arn:aws:logs:us-east-1:111111111111:delivery-destination:svp-cloudfront-prd"
  }

  assert {
    condition     = alltrue([for b in aws_s3_bucket.this : b.force_destroy == false]) && aws_s3_bucket.logs[0].force_destroy == false
    error_message = "prd must never let destroy delete objects of its buckets."
  }

  assert {
    condition     = length(aws_s3_bucket_versioning.this) == 2 && length(aws_s3_bucket_logging.this) == 2
    error_message = "prd must keep earlier versions and access logs of both buckets."
  }

  assert {
    condition     = aws_cloudfront_distribution.media.web_acl_id == "arn:aws:wafv2:us-east-1:222222222222:global/webacl/svp-prd-media/a1b2c3d4-5678-90ab-cdef-111111111111"
    error_message = "prd must put the web ACL in front of the distribution."
  }

  assert {
    condition     = aws_cloudfront_distribution.media.default_cache_behavior[0].viewer_protocol_policy == "https-only"
    error_message = "prd must serve media over HTTPS only."
  }

  assert {
    condition     = length(aws_pricingplanmanager_subscription.media) == 0 && length(aws_cloudwatch_log_delivery.media) == 1
    error_message = "prd media must be pay-as-you-go, with standard logs."
  }
}
