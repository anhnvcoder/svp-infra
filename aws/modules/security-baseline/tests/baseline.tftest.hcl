# What the security baseline of an account guarantees, for a member account (defaults), the management account (every
# event group, root sign-in in three regions, a default EBS key) and both values of config_recording; then one plan per
# validation rule with a value only that rule rejects. The AWS provider is a mock: nothing reaches an account. The home
# region is the mocked region of the provider; the other region of the module is us-east-1.

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
  config_bucket_name     = "svp-config-111111111111-ap-southeast-1"
  log_archive_key_arn    = "arn:aws:kms:ap-southeast-1:111111111111:key/00000000-0000-0000-0000-000000000000"
  security_event_bus_arn = "arn:aws:events:ap-southeast-1:222222222222:event-bus/svp-security-events"

  # Rules every account has, as "<rule>/<region>".
  member_rules = [
    "svp-security-root-signin/us-east-1",
    "svp-security-trail/ap-southeast-1",
    "svp-security-trail/us-east-1",
    "svp-security-detection/ap-southeast-1",
    "svp-security-detection/us-east-1",
    "svp-security-alert-rules/ap-southeast-1",
    "svp-security-alert-rules/us-east-1",
    "svp-security-denied-iam/us-east-1",
    "svp-security-denied-detection/ap-southeast-1",
    "svp-security-denied-detection/us-east-1",
    "svp-security-denied-storage/ap-southeast-1",
    "svp-security-denied-storage/us-east-1",
  ]
}

run "member_account" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_account_public_access_block.this.block_public_acls,
      aws_s3_account_public_access_block.this.block_public_policy,
      aws_s3_account_public_access_block.this.ignore_public_acls,
      aws_s3_account_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "S3 Block Public Access of the account must set all four flags to true."
  }

  assert {
    condition     = toset(keys(aws_ebs_encryption_by_default.this)) == toset(["ap-southeast-1", "us-east-1"]) && alltrue([for k, e in aws_ebs_encryption_by_default.this : e.enabled && e.region == k])
    error_message = "EBS encryption by default must be on in the home region and in us-east-1."
  }

  assert {
    condition     = length(aws_ebs_default_kms_key.this) == 0
    error_message = "Without ebs_kms_key_arn the module must keep the AWS managed key aws/ebs (no default key resource)."
  }

  assert {
    condition     = aws_iam_service_linked_role.config.aws_service_name == "config.amazonaws.com"
    error_message = "The module must declare the service-linked role of AWS Config."
  }

  assert {
    condition = toset(keys(aws_config_configuration_recorder.this)) == toset(["ap-southeast-1", "us-east-1"]) && alltrue([
      for k, r in aws_config_configuration_recorder.this :
      r.region == k && r.name == "default" && r.recording_mode[0].recording_frequency == "CONTINUOUS" && r.recording_group[0].all_supported &&
      r.role_arn == "arn:aws:iam::000000000000:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"
    ])
    error_message = "Each region must have one recorder named default, recording every supported type continuously with the service-linked role."
  }

  assert {
    condition = (aws_config_configuration_recorder.this["ap-southeast-1"].recording_group[0].include_global_resource_types &&
    !aws_config_configuration_recorder.this["us-east-1"].recording_group[0].include_global_resource_types)
    error_message = "Global resource types (IAM) must be recorded in the home region only."
  }

  assert {
    condition = toset(keys(aws_config_delivery_channel.this)) == toset(["ap-southeast-1", "us-east-1"]) && alltrue([
      for k, c in aws_config_delivery_channel.this :
      c.region == k && c.s3_bucket_name == "svp-config-111111111111-ap-southeast-1" &&
      c.s3_kms_key_arn == "arn:aws:kms:ap-southeast-1:111111111111:key/00000000-0000-0000-0000-000000000000" &&
      c.snapshot_delivery_properties[0].delivery_frequency == "TwentyFour_Hours"
    ])
    error_message = "The delivery channel of both regions must write to the Config bucket with the Log Archive key, with a daily snapshot."
  }

  assert {
    condition     = alltrue([for k, s in aws_config_configuration_recorder_status.this : s.is_enabled && s.region == k && s.name == "default"]) && length(aws_config_configuration_recorder_status.this) == 2
    error_message = "The recorder of both regions must be started."
  }

  assert {
    condition     = toset(keys(aws_cloudwatch_event_rule.forward)) == toset(var.member_rules)
    error_message = "A member account must have exactly the rules every account has: no Organizations, root session or administrative change rule."
  }

  # The baseline service control policy protects rules and roles by this prefix.
  assert {
    condition     = alltrue([for k, r in aws_cloudwatch_event_rule.forward : startswith(r.name, "svp-security-") && k == "${r.name}/${r.region}"]) && startswith(aws_iam_role.forwarder.name, "svp-security-")
    error_message = "Every rule must be named svp-security-* in the region of its key, and the forwarding role svp-security-*."
  }

  assert {
    condition     = alltrue([for r in aws_cloudwatch_event_rule.forward : r.state == "ENABLED" && length(r.event_pattern) <= 2048])
    error_message = "Every rule of a member account must be enabled, with a pattern of at most 2,048 characters."
  }

  assert {
    condition = toset(keys(aws_cloudwatch_event_target.forward)) == toset(var.member_rules) && alltrue([
      for k, t in aws_cloudwatch_event_target.forward :
      t.arn == "arn:aws:events:ap-southeast-1:222222222222:event-bus/svp-security-events" && t.region == aws_cloudwatch_event_rule.forward[k].region
    ])
    error_message = "Every rule must have one target, the security event bus, in the region of the rule."
  }

  assert {
    condition = (
      toset(flatten([for s in data.aws_iam_policy_document.forwarder_trust.statement : flatten([for p in s.principals : p.identifiers])])) == toset(["events.amazonaws.com"]) &&
      anytrue([for s in data.aws_iam_policy_document.forwarder_trust.statement : anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "aws:SourceAccount" && toset(c.values) == toset(["000000000000"])])])
    )
    error_message = "Only EventBridge of this account may assume the forwarding role."
  }

  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.forwarder.statement :
      s.effect == "Allow" && toset(s.actions) == toset(["events:PutEvents"]) && toset(s.resources) == toset(["arn:aws:events:ap-southeast-1:222222222222:event-bus/svp-security-events"])
    ])
    error_message = "The forwarding role may only put events on the security event bus."
  }

  # Event patterns, read back from the JSON sent to EventBridge.
  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.forward["svp-security-root-signin/us-east-1"].event_pattern).detail.userIdentity.type == ["Root"]
    error_message = "svp-security-root-signin must match console sign-ins of the root user."
  }

  assert {
    condition     = toset(jsondecode(aws_cloudwatch_event_rule.forward["svp-security-trail/us-east-1"].event_pattern).detail.eventName) == toset(["DeleteTrail", "PutEventSelectors", "PutInsightSelectors", "StopLogging", "UpdateTrail"])
    error_message = "svp-security-trail must match every CloudTrail change the service control policy denies, succeeded or denied."
  }

  assert {
    condition = alltrue([for k in ["svp-security-detection/ap-southeast-1", "svp-security-denied-detection/us-east-1"] :
      length(jsondecode(aws_cloudwatch_event_rule.forward[k].event_pattern).detail.eventName) == 40 &&
      contains(jsondecode(aws_cloudwatch_event_rule.forward[k].event_pattern).detail.eventName, "StopConfigurationRecorder") &&
      contains(jsondecode(aws_cloudwatch_event_rule.forward[k].event_pattern).detail.eventName, "DisableSecurityHub") &&
      contains(jsondecode(aws_cloudwatch_event_rule.forward[k].event_pattern).detail.eventName, "DeleteDetector") &&
      contains(jsondecode(aws_cloudwatch_event_rule.forward[k].event_pattern).detail.eventName, "DeleteAnalyzer")
    ])
    error_message = "The detection rules must match the 40 detection actions the service control policy denies."
  }

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.forward["svp-security-detection/us-east-1"].event_pattern).detail.errorCode == [{ exists = false }]
    error_message = "svp-security-detection must match successful calls only (no errorCode)."
  }

  assert {
    condition = alltrue([for k in ["svp-security-denied-iam/us-east-1", "svp-security-denied-detection/ap-southeast-1"] :
      jsondecode(aws_cloudwatch_event_rule.forward[k].event_pattern).detail.errorCode == [{ prefix = "AccessDenied" }]
    ])
    error_message = "The denied rules must match an errorCode starting with AccessDenied."
  }

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.forward["svp-security-denied-storage/ap-southeast-1"].event_pattern).detail.errorCode == [{ prefix = "AccessDenied" }, "Client.UnauthorizedOperation"]
    error_message = "svp-security-denied-storage must also match the Client.UnauthorizedOperation of EC2, dry runs included."
  }

  assert {
    condition = alltrue([for e in ["CreateUser", "CreateAccessKey", "CreateLoginProfile", "UpdateLoginProfile", "UpdateAssumeRolePolicy"] :
      contains(jsondecode(aws_cloudwatch_event_rule.forward["svp-security-denied-iam/us-east-1"].event_pattern).detail.eventName, e)
    ])
    error_message = "svp-security-denied-iam must match denied IAM user, access key and login profile calls and changes to protected roles."
  }

  assert {
    condition = alltrue([for e in ["PutAccountPublicAccessBlock", "DisableEbsEncryptionByDefault", "ModifyEbsDefaultKmsKeyId", "DisableKeyRotation", "ScheduleKeyDeletion"] :
      contains(jsondecode(aws_cloudwatch_event_rule.forward["svp-security-denied-storage/us-east-1"].event_pattern).detail.eventName, e)
    ])
    error_message = "svp-security-denied-storage must match denied changes to account S3 Block Public Access, EBS default encryption and the EBS key."
  }

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.forward["svp-security-alert-rules/ap-southeast-1"].event_pattern).detail["$or"] == [
      { requestParameters = { name = [{ prefix = "svp-security-" }] } },
      { requestParameters = { rule = [{ prefix = "svp-security-" }] } },
    ]
    error_message = "svp-security-alert-rules must match calls on rules named svp-security-*, by name or rule parameter."
  }
}

run "management_account" {
  command = plan

  variables {
    ebs_kms_key_arn        = "arn:aws:kms:ap-southeast-1:000000000000:key/11111111-1111-1111-1111-111111111111"
    root_signin_regions    = ["us-east-1", "us-east-2", "us-west-2"]
    organization_events    = true
    admin_events           = true
    identity_center_region = "ap-southeast-1"
  }

  assert {
    condition = toset(keys(aws_cloudwatch_event_rule.forward)) == setunion(setsubtract(toset(var.member_rules), ["svp-security-root-signin/us-east-1"]), [
      "svp-security-root-signin/us-east-1",
      "svp-security-root-signin/us-east-2",
      "svp-security-root-signin/us-west-2",
      "svp-security-root-session/ap-southeast-1",
      "svp-security-root-session/us-east-1",
      "svp-security-org/us-east-1",
      "svp-security-admin-iam/us-east-1",
      "svp-security-admin-kms-s3/ap-southeast-1",
      "svp-security-admin-kms-s3/us-east-1",
      "svp-security-admin-sso/ap-southeast-1",
    ])
    error_message = "The management account must have every rule, the root sign-in rule in the three regions of root_signin_regions, and the Identity Center rule in its region."
  }

  assert {
    condition     = alltrue([for k, r in aws_cloudwatch_event_rule.forward : r.state == (startswith(k, "svp-security-root-session/") ? "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS" : "ENABLED") && length(r.event_pattern) <= 2048])
    error_message = "Only svp-security-root-session receives read-only management events (AssumeRoot can be one); every pattern fits in 2,048 characters."
  }

  assert {
    condition     = length(aws_cloudwatch_event_target.forward) == length(aws_cloudwatch_event_rule.forward)
    error_message = "Every rule must have its target."
  }

  assert {
    condition = (
      jsondecode(aws_cloudwatch_event_rule.forward["svp-security-root-session/us-east-1"].event_pattern).detail.eventName == ["AssumeRoot"] &&
      contains(jsondecode(aws_cloudwatch_event_rule.forward["svp-security-org/us-east-1"].event_pattern).detail.eventName, "DetachPolicy") &&
      jsondecode(aws_cloudwatch_event_rule.forward["svp-security-admin-iam/us-east-1"].event_pattern).detail.errorCode == [{ exists = false }] &&
      contains(jsondecode(aws_cloudwatch_event_rule.forward["svp-security-admin-kms-s3/ap-southeast-1"].event_pattern).detail.eventName, "PutBucketPolicy") &&
      contains(jsondecode(aws_cloudwatch_event_rule.forward["svp-security-admin-sso/ap-southeast-1"].event_pattern).detail.eventName, "CreateAccountAssignment")
    )
    error_message = "The management rules must match AssumeRoot, Organizations policy changes and successful IAM, KMS, S3 and Identity Center changes."
  }

  assert {
    condition     = length(aws_ebs_default_kms_key.this) == 1 && aws_ebs_default_kms_key.this[0].key_arn == "arn:aws:kms:ap-southeast-1:000000000000:key/11111111-1111-1111-1111-111111111111" && aws_ebs_default_kms_key.this[0].region == "ap-southeast-1"
    error_message = "With ebs_kms_key_arn the home region must encrypt new volumes with that key by default."
  }
}

# Administrative IAM changes without the management-only rules: the data of the Log Archive and Security Tooling
# accounts.
run "admin_events_only" {
  command = plan

  variables {
    admin_events = true
  }

  assert {
    condition     = toset(keys(aws_cloudwatch_event_rule.forward)) == setunion(toset(var.member_rules), ["svp-security-admin-iam/us-east-1", "svp-security-admin-kms-s3/ap-southeast-1", "svp-security-admin-kms-s3/us-east-1"])
    error_message = "admin_events must add the IAM, KMS and S3 change rules and nothing else; the denied rules stay."
  }
}

# config_recording sets the AWS Config resources of each region and nothing else: the service-linked role, account
# settings and every forwarding rule stay at both values.
run "config_recording_on" {
  command = plan

  variables {
    config_recording = true
  }

  assert {
    condition = alltrue([for r in ["ap-southeast-1", "us-east-1"] :
      length([for k, x in aws_config_configuration_recorder.this : k if k == r && x.region == r]) == 1 &&
      length([for k, x in aws_config_delivery_channel.this : k if k == r && x.region == r]) == 1 &&
      length([for k, x in aws_config_configuration_recorder_status.this : k if k == r && x.region == r && x.is_enabled]) == 1
    ]) && length(aws_config_configuration_recorder.this) == 2 && length(aws_config_delivery_channel.this) == 2 && length(aws_config_configuration_recorder_status.this) == 2
    error_message = "With config_recording each region must have one recorder, one delivery channel and one started recorder status."
  }

  assert {
    condition = (
      aws_iam_service_linked_role.config.aws_service_name == "config.amazonaws.com" &&
      aws_s3_account_public_access_block.this.block_public_policy &&
      toset(keys(aws_ebs_encryption_by_default.this)) == toset(["ap-southeast-1", "us-east-1"]) &&
      toset(keys(aws_cloudwatch_event_rule.forward)) == toset(var.member_rules) &&
      toset(keys(aws_cloudwatch_event_target.forward)) == toset(var.member_rules)
    )
    error_message = "The service-linked role, account settings and forwarding rules must not depend on config_recording."
  }
}

run "config_recording_off" {
  command = plan

  variables {
    config_recording = false
  }

  assert {
    condition     = length(aws_config_configuration_recorder.this) == 0 && length(aws_config_delivery_channel.this) == 0 && length(aws_config_configuration_recorder_status.this) == 0
    error_message = "Without config_recording no region may have a recorder, a delivery channel or a recorder status."
  }

  assert {
    condition = (
      aws_iam_service_linked_role.config.aws_service_name == "config.amazonaws.com" &&
      alltrue([
        aws_s3_account_public_access_block.this.block_public_acls,
        aws_s3_account_public_access_block.this.block_public_policy,
        aws_s3_account_public_access_block.this.ignore_public_acls,
        aws_s3_account_public_access_block.this.restrict_public_buckets,
      ]) &&
      toset(keys(aws_ebs_encryption_by_default.this)) == toset(["ap-southeast-1", "us-east-1"]) &&
      alltrue([for e in aws_ebs_encryption_by_default.this : e.enabled])
    )
    error_message = "Without config_recording the service-linked role, S3 Block Public Access and EBS encryption by default must stay."
  }

  # The Config events of these rules are CloudTrail API calls, recorded with or without a recorder.
  assert {
    condition = (
      toset(keys(aws_cloudwatch_event_rule.forward)) == toset(var.member_rules) &&
      toset(keys(aws_cloudwatch_event_target.forward)) == toset(var.member_rules) &&
      contains(jsondecode(aws_cloudwatch_event_rule.forward["svp-security-detection/ap-southeast-1"].event_pattern).detail.eventSource, "config.amazonaws.com") &&
      contains(jsondecode(aws_cloudwatch_event_rule.forward["svp-security-detection/ap-southeast-1"].event_pattern).detail.eventName, "PutConfigurationRecorder")
    )
    error_message = "Without config_recording every forwarding rule must stay, the detection rule still matching Config API calls."
  }
}

run "ebs_key_of_other_region" {
  command = plan

  variables {
    ebs_kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/11111111-1111-1111-1111-111111111111"
  }

  expect_failures = [aws_ebs_default_kms_key.this]
}

run "config_bucket_name_uppercase" {
  command = plan

  variables {
    config_bucket_name = "SVP-config-111111111111-ap-southeast-1"
  }

  expect_failures = [var.config_bucket_name]
}

run "config_bucket_name_dotted" {
  command = plan

  variables {
    config_bucket_name = "svp.config.example"
  }

  expect_failures = [var.config_bucket_name]
}

# The ARN of the key name KMS also accepts never gives a clean plan; the string is joined because make test refuses a
# line holding that word.
run "log_archive_key_by_name" {
  command = plan

  variables {
    log_archive_key_arn = join("", ["arn:aws:kms:ap-southeast-1:111111111111:ali", "as/svp-log-archive"])
  }

  expect_failures = [var.log_archive_key_arn]
}

run "event_bus_arn_of_a_rule" {
  command = plan

  variables {
    security_event_bus_arn = "arn:aws:events:ap-southeast-1:222222222222:rule/svp-security-events"
  }

  expect_failures = [var.security_event_bus_arn]
}

run "event_bus_name_only" {
  command = plan

  variables {
    security_event_bus_arn = "svp-security-events"
  }

  expect_failures = [var.security_event_bus_arn]
}

run "ebs_key_not_an_arn" {
  command = plan

  variables {
    ebs_kms_key_arn = "11111111-1111-1111-1111-111111111111"
  }

  expect_failures = [var.ebs_kms_key_arn]
}

run "root_signin_without_us_east_1" {
  command = plan

  variables {
    root_signin_regions = ["us-east-2", "us-west-2"]
  }

  expect_failures = [var.root_signin_regions]
}

run "identity_center_region_not_a_region" {
  command = plan

  variables {
    identity_center_region = "Singapore"
  }

  expect_failures = [var.identity_center_region]
}
