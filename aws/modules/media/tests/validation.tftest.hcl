# Validation rules of the module's variables: one plan with valid values, then one plan per rule with a value that only
# that rule rejects; then what the defaults keep, what each new variable adds, and the values of prd. The AWS provider
# is a mock: nothing reaches an account, and data sources return the values below (the provider still validates
# arguments, so policies must be JSON). The plan cannot prove that AWS accepts the plan tier or the managed policy.

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

# What the flat-rate Free plan requires of the distribution, in every env: the plan covers it and the web ACL, and
# the distribution uses only features of the plan (a managed response headers policy, every edge location).
run "flat_rate_plan" {
  command = plan

  assert {
    condition = (aws_pricingplanmanager_subscription.media.plan_family == "CloudFront" &&
      aws_pricingplanmanager_subscription.media.plan_tier == "FREE" &&
    aws_pricingplanmanager_subscription.media.approval_mode == null)
    error_message = "The distribution must be subscribed to the CloudFront flat-rate Free plan, with the default approval mode."
  }

  assert {
    condition     = anytrue([for a in aws_pricingplanmanager_subscription.media.resource_arns : a == var.web_acl_arn])
    error_message = "The plan must cover the web ACL of the distribution."
  }

  assert {
    condition     = aws_cloudfront_distribution.media.web_acl_id == var.web_acl_arn
    error_message = "The distribution must carry the web ACL."
  }

  assert {
    condition = (data.aws_cloudfront_response_headers_policy.simple_cors.name == "Managed-SimpleCORS" &&
    aws_cloudfront_distribution.media.default_cache_behavior[0].response_headers_policy_id == "60669652-455b-4ae9-85a4-c4c02393f86c")
    error_message = "The distribution must answer CORS with the managed policy Managed-SimpleCORS, the only kind the Free plan takes."
  }

  assert {
    condition     = aws_cloudfront_distribution.media.price_class == "PriceClass_All"
    error_message = "The distribution must use every edge location, the price class a flat-rate plan sets."
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
    name_prefix            = "svp-prd"
    account_id             = "222222222222"
    force_destroy          = false
    versioning_enabled     = true
    access_logging_enabled = true
    web_acl_arn            = "arn:aws:wafv2:us-east-1:222222222222:global/webacl/svp-prd-media/a1b2c3d4-5678-90ab-cdef-111111111111"
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
}
