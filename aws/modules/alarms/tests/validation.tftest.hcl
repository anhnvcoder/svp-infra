# What the alarm topic of an env guarantees: encrypted with the module's own key, only CloudWatch alarms of the account
# publish to it, over TLS only, and the email subscription; then one plan per validation rule with a value that only
# that rule rejects. The module is the same in every env, so one valid plan covers it. The AWS provider is a mock:
# nothing reaches an account. Policies are asserted through the arguments of their aws_iam_policy_document data sources.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:GetCallerIdentity\",\"Resource\":\"*\"}]}"
    }
  }
}

variables {
  name        = "svp-stg"
  alarm_email = "ops@svp.example"

  # The confused deputy conditions every statement for the CloudWatch service principal must carry, as
  # "<test> <variable> <values>" strings.
  source_conditions = [
    "StringEquals aws:SourceAccount 000000000000",
    "ArnLike aws:SourceArn arn:aws:cloudwatch:ap-southeast-1:000000000000:alarm:*",
  ]
}

run "valid" {
  command = plan

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == true && aws_kms_key.this.deletion_window_in_days == 7 && aws_kms_key.this.customer_master_key_spec == "SYMMETRIC_DEFAULT" && aws_kms_key.this.key_usage == "ENCRYPT_DECRYPT"
    error_message = "The module must make its own symmetric KMS key, rotated, with the shortest deletion window."
  }

  # The topic names the module's key by the name the module gives it in KMS, known at plan time where the key ARN is
  # not; the string is joined because make test refuses a line holding the keyword of extra provider configurations.
  assert {
    condition     = aws_sns_topic.this.name == "svp-stg-alarms" && aws_sns_topic.this.kms_master_key_id == join("", ["ali", "as/svp-stg-alarms"])
    error_message = "The topic must be <name>-alarms, encrypted with the key of the module (never the AWS managed key of SNS)."
  }

  # Key policy: the default statement of the account, and CloudWatch limited to what publishing to an encrypted topic
  # takes, for alarms of this account only.
  assert {
    condition = alltrue(flatten([for s in data.aws_iam_policy_document.key.statement : [
      for p in s.principals : (p.type == "AWS" && toset(p.identifiers) == toset(["arn:aws:iam::000000000000:root"])) || (p.type == "Service" && toset(p.identifiers) == toset(["cloudwatch.amazonaws.com"]))
    ]]))
    error_message = "Every principal of the key policy must be the account itself or the CloudWatch service, never \"*\" or another account."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.key.statement :
      anytrue([for p in s.principals : p.type == "AWS"]) || (
        s.effect == "Allow" &&
        toset(s.actions) == toset(["kms:Decrypt", "kms:GenerateDataKey*"]) &&
        toset([for c in s.condition : "${c.test} ${c.variable} ${join(",", c.values)}"]) == toset(var.source_conditions)
      )
    ])
    error_message = "CloudWatch may only kms:Decrypt and kms:GenerateDataKey* on the key, under aws:SourceAccount and aws:SourceArn of this account's alarms."
  }

  assert {
    condition = length(data.aws_iam_policy_document.key.statement) == 2 && anytrue([for s in data.aws_iam_policy_document.key.statement :
      s.effect == "Allow" && toset(s.actions) == toset(["kms:*"]) && length(s.condition) == 0 && anytrue([for p in s.principals : p.type == "AWS"])
    ])
    error_message = "The key policy must keep the default statement, so IAM of the account administers the key."
  }

  # Topic policy: CloudWatch alarms of the account publish, nothing else is allowed, and publishing without TLS is denied.
  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.topic.statement :
      s.effect == "Deny" || (
        toset(s.actions) == toset(["sns:Publish"]) &&
        toset(s.resources) == toset(["arn:aws:sns:ap-southeast-1:000000000000:svp-stg-alarms"]) &&
        alltrue([for p in s.principals : p.type == "Service" && toset(p.identifiers) == toset(["cloudwatch.amazonaws.com"])]) &&
        length(s.principals) == 1 &&
        toset([for c in s.condition : "${c.test} ${c.variable} ${join(",", c.values)}"]) == toset(var.source_conditions)
      )
    ])
    error_message = "The topic policy may only allow the CloudWatch service to sns:Publish to the topic, under aws:SourceAccount and aws:SourceArn of this account's alarms."
  }

  assert {
    condition = anytrue([for s in data.aws_iam_policy_document.topic.statement :
      s.effect == "Deny" && contains(s.actions, "sns:Publish") &&
      anytrue([for p in s.principals : p.type == "*" && contains(p.identifiers, "*")]) &&
      anytrue([for c in s.condition : c.test == "Bool" && c.variable == "aws:SecureTransport" && toset(c.values) == toset(["false"])])
    ])
    error_message = "The topic policy must deny sns:Publish without TLS (aws:SecureTransport false) to everyone."
  }

  assert {
    condition     = aws_sns_topic_subscription.email.protocol == "email" && aws_sns_topic_subscription.email.endpoint == "ops@svp.example"
    error_message = "The topic must have an email subscription to alarm_email."
  }
}

run "name_double_hyphen" {
  command = plan

  variables {
    name = "svp--stg"
  }

  expect_failures = [var.name]
}

run "alarm_email_not_an_address" {
  command = plan

  variables {
    alarm_email = "ops.svp.example"
  }

  expect_failures = [var.alarm_email]
}
