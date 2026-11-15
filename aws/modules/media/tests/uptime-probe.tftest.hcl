# The object of the uptime probe: key, body and headers the probe and the cache rely on, in the media bucket. The AWS
# provider is a mock: nothing reaches an account.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
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
  # Fake public key, not a key of any pair: the plan only reads it as text.
  signing_public_keys = {
    a = "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtestkeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-----END PUBLIC KEY-----\n"
  }
}

run "uptime_probe_object" {
  command = plan

  assert {
    condition     = aws_s3_object.uptime_probe.bucket == "svp-stg-media-000000000000-ap-southeast-1"
    error_message = "The probe object must be in the media bucket."
  }

  assert {
    condition     = aws_s3_object.uptime_probe.key == "media/uptime-probe.txt" && aws_s3_object.uptime_probe.content == "ok\n"
    error_message = "The probe object must be media/uptime-probe.txt with the body \"ok\" and a newline."
  }

  assert {
    condition     = aws_s3_object.uptime_probe.content_type == "text/plain" && aws_s3_object.uptime_probe.cache_control == "no-store"
    error_message = "The probe object must be served as text/plain with Cache-Control: no-store."
  }
}
