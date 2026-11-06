# Validation rules of the module's variables: one plan with valid values, then one plan per rule with a value that only
# that rule rejects; then what the defaults keep, what each new variable adds, and the values of prd. The AWS provider
# is a mock: nothing reaches an account, and data sources return the values below (the provider still validates
# arguments, so policies must be JSON).

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }
}

variables {
  name_prefix          = "svp-stg"
  account_id           = "000000000000"
  region               = "ap-southeast-1"
  cors_allowed_origins = ["https://svp.example"]
  force_destroy        = true
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

run "price_class_unknown" {
  command = plan

  variables {
    price_class = "PriceClass_300"
  }

  expect_failures = [var.price_class]
}

run "web_acl_arn_regional" {
  command = plan

  variables {
    web_acl_arn = "arn:aws:wafv2:ap-southeast-1:000000000000:regional/webacl/svp-prd-media/a1b2c3d4-5678-90ab-cdef-111111111111"
  }

  expect_failures = [var.web_acl_arn]
}

# The defaults keep the buckets and the distribution as they were: no versioning, no access log and no log bucket,
# no web ACL.
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

  assert {
    condition     = aws_cloudfront_distribution.media.web_acl_id == ""
    error_message = "By default the distribution must carry no web ACL."
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
    price_class            = "PriceClass_200"
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
    condition     = aws_cloudfront_distribution.media.price_class == "PriceClass_200" && aws_cloudfront_distribution.media.default_cache_behavior[0].viewer_protocol_policy == "https-only"
    error_message = "prd must serve media over HTTPS only from the edges of PriceClass_200."
  }
}
