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
