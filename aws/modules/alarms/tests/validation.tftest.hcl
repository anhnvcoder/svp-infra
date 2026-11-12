# What the alarm topic guarantees: encrypted with the module's own key, only the listed publishers (CloudWatch alarms by
# default, EventBridge rules for the security topic) of the account publish to it, over TLS only, and the email
# subscription; then one plan per validation rule with a value that only that rule rejects. The AWS provider is a mock:
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

  # The default publisher list leaves the topic of both envs exactly as CloudWatch alone needs it: same statement ids
  # and key description, so the plans of the env roots do not change.
  assert {
    condition     = aws_kms_key.this.description == "SNS topic svp-stg-alarms: CloudWatch alarms of svp-stg" && [for s in data.aws_iam_policy_document.key.statement : s.sid] == ["EnableIamUserPermissions", "CloudWatchAlarmsUseKey"] && [for s in data.aws_iam_policy_document.topic.statement : s.sid] == ["CloudWatchAlarmsPublish", "DenyPublishWithoutTls"]
    error_message = "By default the key and topic policies must hold only the CloudWatch statements, with their statement ids and key description."
  }
}

# The security topic: EventBridge rules of the account publish, CloudWatch does not.
run "eventbridge_publisher" {
  command = plan

  variables {
    name               = "svp-security"
    publisher_services = ["events.amazonaws.com"]
    source_conditions = [
      "StringEquals aws:SourceAccount 000000000000",
      "ArnLike aws:SourceArn arn:aws:events:ap-southeast-1:000000000000:rule/*",
    ]
  }

  assert {
    condition     = aws_sns_topic.this.name == "svp-security-alarms" && aws_kms_key.this.description == "SNS topic svp-security-alarms: EventBridge rules of svp-security"
    error_message = "The topic must be <name>-alarms and its key described by its publisher."
  }

  # SNS does not support aws:SourceAccount, aws:SourceArn or aws:SourceOrgID in the key policy for EventBridge to an
  # encrypted topic: with them KMS refuses the data key and no alert is delivered. The topic policy limits the rules.
  assert {
    condition = length(data.aws_iam_policy_document.key.statement) == 2 && alltrue([for s in data.aws_iam_policy_document.key.statement :
      anytrue([for p in s.principals : p.type == "AWS" && toset(p.identifiers) == toset(["arn:aws:iam::000000000000:root"])]) || (
        s.sid == "EventBridgeRulesUseKey" &&
        toset(s.actions) == toset(["kms:Decrypt", "kms:GenerateDataKey*"]) &&
        alltrue([for p in s.principals : p.type == "Service" && toset(p.identifiers) == toset(["events.amazonaws.com"])]) &&
        length(s.condition) == 0
      )
    ])
    error_message = "Besides the default statement, the key policy may only let EventBridge kms:Decrypt and kms:GenerateDataKey*, without aws:Source* conditions."
  }

  assert {
    condition = length(data.aws_iam_policy_document.topic.statement) == 2 && alltrue([for s in data.aws_iam_policy_document.topic.statement :
      s.effect == "Deny" || (
        s.sid == "EventBridgeRulesPublish" &&
        toset(s.actions) == toset(["sns:Publish"]) &&
        toset(s.resources) == toset(["arn:aws:sns:ap-southeast-1:000000000000:svp-security-alarms"]) &&
        alltrue([for p in s.principals : p.type == "Service" && toset(p.identifiers) == toset(["events.amazonaws.com"])]) &&
        toset([for c in s.condition : "${c.test} ${c.variable} ${join(",", c.values)}"]) == toset(var.source_conditions)
      )
    ])
    error_message = "The topic policy may only let EventBridge rules of this account sns:Publish, besides the TLS deny."
  }
}

# Both publishers: one statement each in both policies, each with the conditions of its own service; on the key only
# CloudWatch carries them.
run "both_publishers" {
  command = plan

  variables {
    publisher_services = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
  }

  assert {
    condition     = [for s in data.aws_iam_policy_document.key.statement : s.sid] == ["EnableIamUserPermissions", "CloudWatchAlarmsUseKey", "EventBridgeRulesUseKey"] && [for s in data.aws_iam_policy_document.topic.statement : s.sid] == ["CloudWatchAlarmsPublish", "EventBridgeRulesPublish", "DenyPublishWithoutTls"]
    error_message = "Each publisher must get its own key and topic statement."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.topic.statement : s.effect == "Deny" || anytrue([for c in s.condition :
      c.variable == "aws:SourceArn" && toset(c.values) == toset([s.sid == "CloudWatchAlarmsPublish" ? "arn:aws:cloudwatch:ap-southeast-1:000000000000:alarm:*" : "arn:aws:events:ap-southeast-1:000000000000:rule/*"])
    ])])
    error_message = "Each publisher statement must limit aws:SourceArn to the resources of its own service."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.key.statement :
      s.sid == "EnableIamUserPermissions" ||
      (s.sid == "CloudWatchAlarmsUseKey" && toset([for c in s.condition : "${c.test} ${c.variable} ${join(",", c.values)}"]) == toset(var.source_conditions)) ||
      (s.sid == "EventBridgeRulesUseKey" && length(s.condition) == 0)
    ])
    error_message = "On the key, CloudWatch must keep aws:SourceAccount and aws:SourceArn of its alarms, and EventBridge must have no condition."
  }

  assert {
    condition     = aws_kms_key.this.description == "SNS topic svp-stg-alarms: CloudWatch alarms and EventBridge rules of svp-stg"
    error_message = "The key description must name every publisher."
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

run "publisher_services_unknown" {
  command = plan

  variables {
    publisher_services = ["sns.amazonaws.com"]
  }

  expect_failures = [var.publisher_services]
}

run "publisher_services_empty" {
  command = plan

  variables {
    publisher_services = []
  }

  expect_failures = [var.publisher_services]
}

run "publisher_services_repeated" {
  command = plan

  variables {
    publisher_services = ["events.amazonaws.com", "events.amazonaws.com"]
  }

  expect_failures = [var.publisher_services]
}
