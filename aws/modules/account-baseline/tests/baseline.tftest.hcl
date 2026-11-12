# What the baseline of a member account guarantees: who may use the state key, how the state bucket is protected, the
# name of the zone, the delegation of child zones and the four budget alerts; then one plan per validation rule with a
# value that only that rule rejects. The AWS provider is a mock: nothing reaches an account. Policies are asserted
# through the arguments of their aws_iam_policy_document data sources (the mock returns a fixed JSON for them).

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }
}

variables {
  env              = "stg"
  account_id       = "111111111111"
  region           = "ap-southeast-1"
  zone_name        = "stg.aws.svp.example"
  budget_limit_usd = 20
  budget_emails    = ["you@svp.example"]

  # Four name servers of a child zone, in the form Route 53 gives them.
  child_servers = ["ns-1.awsdns-00.org", "ns-2.awsdns-01.net", "ns-3.awsdns-02.com", "ns-4.awsdns-03.co.uk"]

  # CAA values of the zone apex: the four CAs of ACM, for single names and wildcards.
  caa_records = [
    "0 issue \"amazon.com\"", "0 issue \"amazontrust.com\"", "0 issue \"awstrust.com\"", "0 issue \"amazonaws.com\"",
    "0 issuewild \"amazon.com\"", "0 issuewild \"amazontrust.com\"", "0 issuewild \"awstrust.com\"", "0 issuewild \"amazonaws.com\"",
  ]

  # Topic of the DNSSEC alarms, in us-east-1 as the Route 53 metrics.
  dns_topic = "arn:aws:sns:us-east-1:222222222222:svp-prd-dns-alarms"

  # Every action that reads or writes data with a KMS key; none may reach anyone but the SvpAdmin roles.
  crypto_actions = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:GenerateDataKey", "kms:GenerateDataKey*", "kms:GenerateDataKeyWithoutPlaintext", "kms:*"]
}

run "stg" {
  command = plan

  # Key policy: no principal "*", the account administers without using the key, only the SvpAdmin roles use it.
  assert {
    condition = alltrue(flatten([for s in data.aws_iam_policy_document.state_key.statement : [
      for p in s.principals : p.type == "AWS" && toset(p.identifiers) == toset(["arn:aws:iam::111111111111:root"])
    ]]))
    error_message = "Every principal of the key policy must be the account itself, never \"*\" or another account."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.state_key.statement :
      length(setintersection(toset(s.actions), toset(var.crypto_actions))) == 0 || (
        length(s.condition) == 1 &&
        one(s.condition).test == "ArnLike" &&
        one(s.condition).variable == "aws:PrincipalArn" &&
        toset(one(s.condition).values) == toset([
          "arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_SvpAdmin_*",
          # The regional form, joined because make test refuses a line holding the end of a block comment.
          join("/", ["arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com", "*", "AWSReservedSSO_SvpAdmin_*"]),
        ])
      )
    ])
    error_message = "A key policy statement that allows encrypting or decrypting must be limited by ArnLike aws:PrincipalArn to the SvpAdmin roles."
  }

  assert {
    condition = anytrue([for s in data.aws_iam_policy_document.state_key.statement :
      s.effect == "Allow" && toset(["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*"]) == setintersection(toset(s.actions), toset(["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*"]))
    ])
    error_message = "The SvpAdmin roles must be allowed kms:Encrypt, kms:Decrypt and kms:GenerateDataKey*, which the S3 backend needs."
  }

  assert {
    condition = anytrue([for s in data.aws_iam_policy_document.state_key.statement :
      s.effect == "Allow" && length(s.condition) == 0 && contains(s.actions, "kms:Put*") && contains(s.actions, "kms:ScheduleKeyDeletion")
    ])
    error_message = "The account must administer the key (kms:Put*, kms:ScheduleKeyDeletion) through IAM, so the key cannot become unmanageable."
  }

  assert {
    condition     = aws_kms_key.state.enable_key_rotation && aws_kms_key.state.deletion_window_in_days == 30
    error_message = "The state key must rotate and wait 30 days before deletion."
  }

  # Bucket: name, versioning, KMS encryption, no public access, ACLs off, TLS only.
  assert {
    condition     = aws_s3_bucket.state.bucket == "svp-tfstate-111111111111-ap-southeast-1"
    error_message = "The state bucket must be svp-tfstate-<account>-<region>."
  }

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "The state bucket must keep versions."
  }

  assert {
    condition = alltrue([for r in aws_s3_bucket_server_side_encryption_configuration.state.rule :
      one(r.apply_server_side_encryption_by_default).sse_algorithm == "aws:kms" && r.bucket_key_enabled
    ]) && length(aws_s3_bucket_server_side_encryption_configuration.state.rule) == 1
    error_message = "The state bucket must encrypt with SSE-KMS (the state key) and the S3 Bucket Key."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.state.block_public_acls &&
      aws_s3_bucket_public_access_block.state.block_public_policy &&
      aws_s3_bucket_public_access_block.state.ignore_public_acls &&
      aws_s3_bucket_public_access_block.state.restrict_public_buckets
    )
    error_message = "The state bucket must block every form of public access."
  }

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.state.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "The state bucket must have ACLs off (BucketOwnerEnforced)."
  }

  assert {
    condition = anytrue([for s in data.aws_iam_policy_document.state_bucket.statement :
      s.effect == "Deny" && contains(s.actions, "s3:*") && anytrue([for c in s.condition :
        c.test == "Bool" && c.variable == "aws:SecureTransport" && toset(c.values) == toset(["false"])
      ])
    ])
    error_message = "The state bucket policy must deny every request without TLS."
  }

  # Zone and budget.
  assert {
    condition     = aws_route53_zone.env.name == "stg.aws.svp.example"
    error_message = "The zone must be named zone_name."
  }

  assert {
    condition     = length(aws_route53_record.delegation) == 0
    error_message = "Without delegated_subdomains the zone must hold no delegation record."
  }

  assert {
    condition     = aws_budgets_budget.monthly.name == "svp-stg-monthly" && aws_budgets_budget.monthly.limit_amount == "20.00" && aws_budgets_budget.monthly.time_unit == "MONTHLY"
    error_message = "The budget must be svp-<env>-monthly with the given monthly limit."
  }

  assert {
    condition = toset([for n in nonsensitive(aws_budgets_budget.monthly.notification) : "${n.notification_type}/${n.threshold}/${n.threshold_type}/${n.comparison_operator}"]) == toset([
      "ACTUAL/50/PERCENTAGE/GREATER_THAN",
      "ACTUAL/80/PERCENTAGE/GREATER_THAN",
      "ACTUAL/100/PERCENTAGE/GREATER_THAN",
      "FORECASTED/100/PERCENTAGE/GREATER_THAN",
    ])
    error_message = "The budget must alert at 50, 80 and 100 percent of actual cost and 100 percent of forecast cost."
  }

  assert {
    condition = (
      aws_route53_record.caa.name == "stg.aws.svp.example" && aws_route53_record.caa.type == "CAA" &&
      toset(aws_route53_record.caa.records) == toset(var.caa_records) && length(aws_route53_record.caa.records) == 8
    )
    error_message = "The zone apex must hold CAA issue and issuewild for exactly the four CAs of ACM."
  }

  # DNSSEC and the query log are off by default (the stg zone).
  assert {
    condition = alltrue([
      length(aws_kms_key.dnssec) == 0,
      length(aws_route53_key_signing_key.this) == 0,
      length(aws_route53_hosted_zone_dnssec.this) == 0,
      length(aws_cloudwatch_metric_alarm.dnssec) == 0,
      length(aws_cloudwatch_log_group.query_log) == 0,
      length(aws_cloudwatch_log_resource_policy.query_log) == 0,
      length(aws_route53_query_log.this) == 0,
    ])
    error_message = "Without dnssec_enabled and query_log_enabled, the zone must have no DNSSEC key, signing, alarm or query log."
  }
}

run "prd" {
  command = plan

  variables {
    env        = "prd"
    account_id = "222222222222"
    zone_name  = "aws.svp.example"
    delegated_subdomains = {
      "stg.aws.svp.example" = var.child_servers
    }
  }

  assert {
    condition     = aws_route53_zone.env.name == "aws.svp.example" && aws_s3_bucket.state.bucket == "svp-tfstate-222222222222-ap-southeast-1"
    error_message = "The names must follow zone_name and account_id."
  }

  assert {
    condition = (
      length(aws_route53_record.delegation) == 1 &&
      aws_route53_record.delegation["stg.aws.svp.example"].name == "stg.aws.svp.example" &&
      aws_route53_record.delegation["stg.aws.svp.example"].type == "NS" &&
      aws_route53_record.delegation["stg.aws.svp.example"].ttl == 172800 &&
      toset(aws_route53_record.delegation["stg.aws.svp.example"].records) == toset(var.child_servers)
    )
    error_message = "Each entry of delegated_subdomains must become an NS record with TTL 172800 and exactly its four name servers."
  }

  assert {
    condition = alltrue(flatten([for s in data.aws_iam_policy_document.state_key.statement : concat(
      [for p in s.principals : toset(p.identifiers) == toset(["arn:aws:iam::222222222222:root"])],
      [for c in s.condition : alltrue([for v in c.values : startswith(v, "arn:aws:iam::222222222222:role/aws-reserved/sso.amazonaws.com/")])],
    )]))
    error_message = "The key policy must name only the account of the baseline."
  }

  assert {
    condition     = aws_route53_record.caa.name == "aws.svp.example" && toset(aws_route53_record.caa.records) == toset(var.caa_records)
    error_message = "The prd zone apex must hold the same CAA values."
  }
}

# The prd zone: DNSSEC signing with its key in us-east-1, two page alarms and the query log.
run "dnssec_query_log" {
  command = plan

  variables {
    env               = "prd"
    account_id        = "222222222222"
    zone_name         = "aws.svp.example"
    dnssec_enabled    = true
    query_log_enabled = true
    alarm_topic_arn   = var.dns_topic
  }

  assert {
    condition = (
      length(aws_kms_key.dnssec) == 1 &&
      aws_kms_key.dnssec[0].region == "us-east-1" &&
      aws_kms_key.dnssec[0].customer_master_key_spec == "ECC_NIST_P256" &&
      aws_kms_key.dnssec[0].key_usage == "SIGN_VERIFY" &&
      aws_kms_key.dnssec[0].deletion_window_in_days == 30
    )
    error_message = "DNSSEC must use an ECC_NIST_P256 SIGN_VERIFY key in us-east-1, the key Route 53 requires."
  }

  # Key policy: the account administers through IAM; the DNSSEC service signs for hosted zones of this account only and
  # creates grants for AWS resources only.
  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.dnssec_key[0].statement :
      anytrue([for p in s.principals : p.type == "AWS" && toset(p.identifiers) == toset(["arn:aws:iam::222222222222:root"])]) ||
      (
        alltrue([for p in s.principals : p.type == "Service" && toset(p.identifiers) == toset(["dnssec-route53.amazonaws.com"])]) &&
        (
          (toset(s.actions) == toset(["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]) &&
            toset([for c in s.condition : "${c.test} ${c.variable} ${join(",", c.values)}"]) == toset([
              "StringEquals aws:SourceAccount 222222222222",
              "ArnLike aws:SourceArn arn:aws:route53:::hostedzone/*",
          ])) ||
          (toset(s.actions) == toset(["kms:CreateGrant"]) &&
          toset([for c in s.condition : "${c.test} ${c.variable} ${join(",", c.values)}"]) == toset(["Bool kms:GrantIsForAWSResource true"]))
        )
      )
    ]) && length(data.aws_iam_policy_document.dnssec_key[0].statement) == 3
    error_message = "The DNSSEC key policy must hold the account statement and the two statements of the Route 53 DNSSEC guide, with their conditions."
  }

  assert {
    condition = (
      aws_route53_key_signing_key.this[0].status == "ACTIVE" &&
      aws_route53_key_signing_key.this[0].name == "svp_prd_ksk" &&
      aws_route53_hosted_zone_dnssec.this[0].signing_status == "SIGNING"
    )
    error_message = "With dnssec_enabled the zone must be signed by an ACTIVE key signing key."
  }

  # The mock does not check the name against the API, which takes 3 to 128 letters, digits and underscores.
  assert {
    condition     = can(regex("^[a-zA-Z0-9_]{3,128}$", aws_route53_key_signing_key.this[0].name))
    error_message = "The key signing key name must be 3 to 128 letters, digits and underscores, as CreateKeySigningKey requires."
  }

  assert {
    condition = (
      toset(keys(aws_cloudwatch_metric_alarm.dnssec)) == toset(["dnssec-internal-failure", "dnssec-ksk-action-needed"]) &&
      alltrue([for k, a in aws_cloudwatch_metric_alarm.dnssec :
        a.alarm_name == "svp-prd-${k}" &&
        a.region == "us-east-1" &&
        a.namespace == "AWS/Route53" &&
        a.tags["Severity"] == "page" &&
        strcontains(a.alarm_description, "https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/${k}.md") &&
        a.alarm_actions == toset([var.dns_topic]) && a.ok_actions == toset([var.dns_topic]) &&
        a.comparison_operator == "GreaterThanOrEqualToThreshold" && a.threshold == 1 && a.statistic == "Sum"
      ]) &&
      aws_cloudwatch_metric_alarm.dnssec["dnssec-internal-failure"].metric_name == "DNSSECInternalFailure" &&
      aws_cloudwatch_metric_alarm.dnssec["dnssec-ksk-action-needed"].metric_name == "DNSSECKeySigningKeysNeedingAction"
    )
    error_message = "DNSSEC must have the two page alarms svp-<env>-dnssec-internal-failure and svp-<env>-dnssec-ksk-action-needed in us-east-1, with the runbook of the same name, to alarm_topic_arn."
  }

  assert {
    condition = (
      aws_cloudwatch_log_group.query_log[0].region == "us-east-1" &&
      aws_cloudwatch_log_group.query_log[0].name == "/aws/route53/aws.svp.example" &&
      aws_cloudwatch_log_group.query_log[0].retention_in_days == 90 &&
      aws_cloudwatch_log_resource_policy.query_log[0].region == "us-east-1" &&
      length(aws_route53_query_log.this) == 1
    )
    error_message = "The query log must go to /aws/route53/<zone_name> in us-east-1, kept 90 days, under a resource policy of us-east-1."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.query_log[0].statement :
      toset(s.actions) == toset(["logs:CreateLogStream", "logs:PutLogEvents"]) &&
      toset(s.resources) == toset(["arn:aws:logs:us-east-1:222222222222:log-group:/aws/route53/aws.svp.example:*"]) &&
      alltrue([for p in s.principals : p.type == "Service" && toset(p.identifiers) == toset(["route53.amazonaws.com"])]) &&
      anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "aws:SourceAccount" && toset(c.values) == toset(["222222222222"])]) &&
      anytrue([for c in s.condition : c.test == "ArnEquals" && c.variable == "aws:SourceArn"])
    ])
    error_message = "Only Route 53, for the zone of this account, may write to the query log group."
  }
}

# Signing stopped (the way back after the DS record is gone): the key signing key stays ACTIVE and the key stays.
run "dnssec_not_signing" {
  command = plan

  variables {
    env             = "prd"
    account_id      = "222222222222"
    zone_name       = "aws.svp.example"
    dnssec_enabled  = true
    dnssec_signing  = false
    alarm_topic_arn = var.dns_topic
  }

  assert {
    condition = (
      aws_route53_hosted_zone_dnssec.this[0].signing_status == "NOT_SIGNING" &&
      aws_route53_key_signing_key.this[0].status == "ACTIVE" &&
      length(aws_kms_key.dnssec) == 1
    )
    error_message = "dnssec_signing = false must stop signing only: the key signing key stays ACTIVE and the KMS key stays."
  }

  assert {
    condition     = length(aws_route53_query_log.this) == 0
    error_message = "query_log_enabled is separate from DNSSEC."
  }
}

run "env_uppercase" {
  command = plan

  variables {
    env = "STG"
  }

  expect_failures = [var.env]
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

run "zone_name_trailing_dot" {
  command = plan

  variables {
    zone_name = "aws.svp.example."
  }

  expect_failures = [var.zone_name]
}

run "delegated_subdomains_zone_itself" {
  command = plan

  variables {
    zone_name = "aws.svp.example"
    delegated_subdomains = {
      "aws.svp.example" = var.child_servers
    }
  }

  expect_failures = [var.delegated_subdomains]
}

run "delegated_subdomains_outside_zone" {
  command = plan

  variables {
    zone_name = "aws.svp.example"
    delegated_subdomains = {
      "stg.other.example" = var.child_servers
    }
  }

  expect_failures = [var.delegated_subdomains]
}

run "delegated_subdomains_three_servers" {
  command = plan

  variables {
    zone_name = "aws.svp.example"
    delegated_subdomains = {
      "stg.aws.svp.example" = ["ns-1.awsdns-00.org", "ns-2.awsdns-01.net", "ns-3.awsdns-02.com"]
    }
  }

  expect_failures = [var.delegated_subdomains]
}

run "delegated_subdomains_repeated_server" {
  command = plan

  variables {
    zone_name = "aws.svp.example"
    delegated_subdomains = {
      "stg.aws.svp.example" = ["ns-1.awsdns-00.org", "ns-2.awsdns-01.net", "ns-3.awsdns-02.com", "ns-1.awsdns-00.org"]
    }
  }

  expect_failures = [var.delegated_subdomains]
}

run "budget_limit_zero" {
  command = plan

  variables {
    budget_limit_usd = 0
  }

  expect_failures = [var.budget_limit_usd]
}

run "budget_emails_empty" {
  command = plan

  variables {
    budget_emails = []
  }

  expect_failures = [var.budget_emails]
}

run "dnssec_without_topic" {
  command = plan

  variables {
    dnssec_enabled = true
  }

  expect_failures = [var.alarm_topic_arn]
}

run "dnssec_topic_other_region" {
  command = plan

  variables {
    dnssec_enabled  = true
    alarm_topic_arn = "arn:aws:sns:ap-southeast-1:111111111111:svp-stg-alarms"
  }

  expect_failures = [var.alarm_topic_arn]
}
