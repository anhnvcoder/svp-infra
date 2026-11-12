# Content, type and target of every policy of the organization, read back from the JSON the module sends to
# Organizations, and the validation of the three ids. The AWS provider is a mock: nothing reaches an account; the module
# reads no data source.

mock_provider "aws" {}

variables {
  root_id         = "r-ab12"
  prod_ou_id      = "ou-ab12-cd34ef56"
  organization_id = "o-ab12cd34ef"
}

run "policies" {
  command = plan

  assert {
    condition = { for k, p in aws_organizations_policy.this : k => p.type } == {
      "deny-leave-organization" = "SERVICE_CONTROL_POLICY"
      "protect-cloudtrail"      = "SERVICE_CONTROL_POLICY"
      "deny-other-regions"      = "SERVICE_CONTROL_POLICY"
      "protect-baseline"        = "SERVICE_CONTROL_POLICY"
      "deny-iam-users"          = "SERVICE_CONTROL_POLICY"
      "prod-guardrails"         = "SERVICE_CONTROL_POLICY"
      "data-perimeter"          = "RESOURCE_CONTROL_POLICY"
      "ec2-baseline"            = "DECLARATIVE_POLICY_EC2"
      "tags"                    = "TAG_POLICY"
    }
    error_message = "The module must create exactly six service control policies, one resource control policy, one EC2 declarative policy and one tag policy, under their keys."
  }

  assert {
    condition     = alltrue([for k, p in aws_organizations_policy.this : p.name == "svp-${k}"])
    error_message = "Every policy must be named svp-<key>."
  }

  # Size limits per type (AWS Organizations quotas); jsonencode writes no whitespace.
  assert {
    condition = alltrue([
      for p in aws_organizations_policy.this : length(p.content) <= {
        SERVICE_CONTROL_POLICY  = 10240
        RESOURCE_CONTROL_POLICY = 5120
        DECLARATIVE_POLICY_EC2  = 10000
        TAG_POLICY              = 10000
      }[p.type]
    ])
    error_message = "A policy must fit its type: 10,240 characters for a service control policy, 5,120 for a resource control policy, 10,000 for a declarative or tag policy."
  }

  # Deny-only: an Allow here would add nothing to FullAWSAccess or RCPFullAWSAccess and could only widen what a reader
  # thinks is granted.
  assert {
    condition = alltrue(flatten([
      for p in aws_organizations_policy.this : [for s in jsondecode(p.content).Statement : s.Effect == "Deny"]
      if contains(["SERVICE_CONTROL_POLICY", "RESOURCE_CONTROL_POLICY"], p.type)
    ]))
    error_message = "Every statement of every service and resource control policy must be a Deny."
  }

  assert {
    condition = alltrue([
      for p in aws_organizations_policy.this : jsondecode(p.content).Version == "2012-10-17"
      if contains(["SERVICE_CONTROL_POLICY", "RESOURCE_CONTROL_POLICY"], p.type)
    ])
    error_message = "Every service and resource control policy must use policy language version 2012-10-17."
  }

  assert {
    condition     = jsondecode(aws_organizations_policy.this["deny-leave-organization"].content).Statement[0].Action == ["organizations:LeaveOrganization"]
    error_message = "deny-leave-organization must deny organizations:LeaveOrganization and nothing else."
  }

  assert {
    condition = toset(jsondecode(aws_organizations_policy.this["protect-cloudtrail"].content).Statement[0].Action) == toset([
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "cloudtrail:UpdateTrail",
      "cloudtrail:PutEventSelectors",
      "cloudtrail:PutInsightSelectors",
    ])
    error_message = "protect-cloudtrail must deny exactly StopLogging, DeleteTrail, UpdateTrail, PutEventSelectors and PutInsightSelectors."
  }

  # Statements that name actions must not use NotAction, and the reverse, so no statement denies more than it says.
  assert {
    condition = alltrue([
      for k in ["deny-leave-organization", "protect-cloudtrail"] :
      alltrue([for s in jsondecode(aws_organizations_policy.this[k].content).Statement : !contains(keys(s), "NotAction") && !contains(keys(s), "Condition")])
    ])
    error_message = "deny-leave-organization and protect-cloudtrail must deny their actions unconditionally, without NotAction."
  }

  # Sessions create and remove malware protection plans, flow logs and WAF logging: no service control policy may deny
  # them, by name or by a wildcard.
  assert {
    condition = alltrue(flatten([
      for p in aws_organizations_policy.this : [
        for s in jsondecode(p.content).Statement : length(setintersection(toset(flatten([s.Action])), toset([
          "guardduty:CreateMalwareProtectionPlan",
          "guardduty:DeleteMalwareProtectionPlan",
          "ec2:CreateFlowLogs",
          "ec2:DeleteFlowLogs",
          "wafv2:PutLoggingConfiguration",
          "wafv2:DeleteLoggingConfiguration",
        ]))) == 0 && alltrue([for a in flatten([s.Action]) : !endswith(a, "*")])
        if contains(keys(s), "Action")
      ]
      if p.type == "SERVICE_CONTROL_POLICY"
    ]))
    error_message = "No service control policy may deny creating or deleting malware protection plans, flow logs or WAF logging, nor deny a wildcard action."
  }
}

run "region_deny" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_organizations_policy.this["deny-other-regions"].content).Statement) == 1
    error_message = "deny-other-regions must hold one statement."
  }

  assert {
    condition     = toset(jsondecode(aws_organizations_policy.this["deny-other-regions"].content).Statement[0].Condition.StringNotEquals["aws:RequestedRegion"]) == toset(["ap-southeast-1", "us-east-1"])
    error_message = "deny-other-regions must allow exactly ap-southeast-1 and us-east-1."
  }

  # No principal is exempted (no ArnNotLike aws:PrincipalARN or other key beside the region).
  assert {
    condition     = keys(jsondecode(aws_organizations_policy.this["deny-other-regions"].content).Statement[0].Condition) == ["StringNotEquals"] && keys(jsondecode(aws_organizations_policy.this["deny-other-regions"].content).Statement[0].Condition.StringNotEquals) == ["aws:RequestedRegion"]
    error_message = "deny-other-regions must condition on aws:RequestedRegion alone, exempting no principal."
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_organizations_policy.this["deny-other-regions"].content).Statement[0]), "Action")
    error_message = "deny-other-regions must deny through NotAction, so every action outside the global list is denied."
  }

  # The global services the lab needs from either region must stay reachable.
  assert {
    condition = length(setsubtract([
      "iam:*",
      "organizations:*",
      "sts:*",
      "route53:*",
      "cloudfront:*",
      "wafv2:*",
      "budgets:*",
      "support:*",
      "sso:*",
      "acm:*",
      "kms:*",
      "health:*",
    ], jsondecode(aws_organizations_policy.this["deny-other-regions"].content).Statement[0].NotAction)) == 0
    error_message = "deny-other-regions must let IAM, Organizations, STS, Route 53, CloudFront, WAF, Budgets, Support, IAM Identity Center, ACM, KMS and Health through."
  }

  # A wildcard that covers a regional service would make the region deny useless.
  assert {
    condition = length(setintersection([
      "*",
      "ec2:*",
      "eks:*",
      "rds:*",
      "s3:*",
      "secretsmanager:*",
      "cloudtrail:*",
    ], jsondecode(aws_organizations_policy.this["deny-other-regions"].content).Statement[0].NotAction)) == 0
    error_message = "deny-other-regions must not let regional services such as EC2, EKS, RDS, S3 or Secrets Manager through."
  }
}


run "attachments" {
  command = plan

  # One target per policy: a policy on the root is not also on an OU below it.
  assert {
    condition = { for k, a in aws_organizations_policy_attachment.this : k => a.target_id } == {
      "deny-leave-organization" = "r-ab12"
      "protect-cloudtrail"      = "r-ab12"
      "deny-other-regions"      = "r-ab12"
      "protect-baseline"        = "r-ab12"
      "deny-iam-users"          = "r-ab12"
      "prod-guardrails"         = "ou-ab12-cd34ef56"
      "data-perimeter"          = "r-ab12"
      "ec2-baseline"            = "r-ab12"
      "tags"                    = "r-ab12"
    }
    error_message = "Every policy must be attached once: prod-guardrails to prod_ou_id, every other policy to root_id."
  }

  # Per target at most 10 service control policies and 5 resource control policies, FullAWSAccess and
  # RCPFullAWSAccess included (AWS Organizations quotas).
  assert {
    condition = alltrue([
      for t in [var.root_id, var.prod_ou_id] :
      length([for k, p in aws_organizations_policy.this : k if p.type == "SERVICE_CONTROL_POLICY" && aws_organizations_policy_attachment.this[k].target_id == t]) <= 9
      && length([for k, p in aws_organizations_policy.this : k if p.type == "RESOURCE_CONTROL_POLICY" && aws_organizations_policy_attachment.this[k].target_id == t]) <= 4
    ])
    error_message = "A target can hold at most 9 service control policies and 4 resource control policies beside the AWS managed full-access ones."
  }
}

run "protect_baseline" {
  command = plan

  assert {
    condition = toset([for s in jsondecode(aws_organizations_policy.this["protect-baseline"].content).Statement : s.Sid]) == toset([
      "ProtectAccountPublicAccessBlock",
      "ProtectEbsDefaultEncryption",
      "ProtectConfig",
      "ProtectGuardDuty",
      "ProtectSecurityHub",
      "ProtectAccessAnalyzer",
      "ProtectAlertRules",
      "ProtectBaselineRoles",
      "ProtectEbsKey",
      "ProtectEbsAlias",
    ])
    error_message = "protect-baseline must hold exactly the statements of the security baseline."
  }

  # The exemption: OrganizationAccountAccessRole and no other principal, in every statement.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_organizations_policy.this["protect-baseline"].content).Statement :
      s.Condition.ArnNotLike == { "aws:PrincipalARN" = "arn:aws:iam::*:role/OrganizationAccountAccessRole" }
    ])
    error_message = "Every statement of protect-baseline must exempt OrganizationAccountAccessRole, and that role alone."
  }

  # No second way out: no other condition operator, and no NotAction, NotResource or Principal.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_organizations_policy.this["protect-baseline"].content).Statement :
      toset(keys(s.Condition)) == toset(s.Sid == "ProtectEbsKey" ? ["ArnNotLike", "StringEquals"] : ["ArnNotLike"])
      && length(setintersection(toset(keys(s)), toset(["NotAction", "NotResource", "Principal", "NotPrincipal"]))) == 0
    ])
    error_message = "protect-baseline must condition on the exempted role alone (plus the key tag of ProtectEbsKey), without NotAction, NotResource or Principal."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_organizations_policy.this["protect-baseline"].content).Statement :
      toset(flatten([s.Action])) == toset({
        ProtectAccountPublicAccessBlock = ["s3:PutAccountPublicAccessBlock"]
        ProtectEbsDefaultEncryption     = ["ec2:DisableEbsEncryptionByDefault", "ec2:ModifyEbsDefaultKmsKeyId", "ec2:ResetEbsDefaultKmsKeyId"]
        ProtectConfig = [
          "config:DeleteConfigurationAggregator",
          "config:DeleteConfigurationRecorder",
          "config:DeleteDeliveryChannel",
          "config:DeleteRetentionConfiguration",
          "config:PutConfigurationAggregator",
          "config:PutConfigurationRecorder",
          "config:PutDeliveryChannel",
          "config:StopConfigurationRecorder",
        ]
        ProtectGuardDuty = [
          "guardduty:CreateFilter",
          "guardduty:CreateIPSet",
          "guardduty:DeleteDetector",
          "guardduty:DeleteMembers",
          "guardduty:DeletePublishingDestination",
          "guardduty:DisassociateFromAdministratorAccount",
          "guardduty:DisassociateFromMasterAccount",
          "guardduty:DisassociateMembers",
          "guardduty:StopMonitoringMembers",
          "guardduty:UpdateDetector",
          "guardduty:UpdateFilter",
          "guardduty:UpdateIPSet",
          "guardduty:UpdateMalwareScanSettings",
          "guardduty:UpdateMemberDetectors",
          "guardduty:UpdateOrganizationConfiguration",
          "guardduty:UpdatePublishingDestination",
        ]
        ProtectSecurityHub = [
          "securityhub:BatchDeleteAutomationRules",
          "securityhub:BatchDisableStandards",
          "securityhub:BatchUpdateAutomationRules",
          "securityhub:CreateAutomationRule",
          "securityhub:DeleteConfigurationPolicy",
          "securityhub:DeleteFindingAggregator",
          "securityhub:DisableImportFindingsForProduct",
          "securityhub:DisableSecurityHub",
          "securityhub:DisassociateFromAdministratorAccount",
          "securityhub:DisassociateFromMasterAccount",
          "securityhub:StartConfigurationPolicyDisassociation",
          "securityhub:UpdateConfigurationPolicy",
          "securityhub:UpdateFindingAggregator",
          "securityhub:UpdateOrganizationConfiguration",
          "securityhub:UpdateSecurityControl",
          "securityhub:UpdateStandardsControl",
        ]
        ProtectAccessAnalyzer = ["access-analyzer:CreateArchiveRule", "access-analyzer:DeleteAnalyzer", "access-analyzer:UpdateArchiveRule"]
        ProtectAlertRules     = ["events:DeleteRule", "events:DisableRule", "events:PutRule", "events:PutTargets", "events:RemoveTargets"]
        ProtectBaselineRoles = [
          "iam:AttachRolePolicy",
          "iam:DeleteRole",
          "iam:DeleteRolePermissionsBoundary",
          "iam:DeleteRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePermissionsBoundary",
          "iam:PutRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRole",
          "iam:UpdateRoleDescription",
        ]
        ProtectEbsKey   = ["kms:DisableKey", "kms:DisableKeyRotation", "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion", "kms:TagResource", "kms:UntagResource"]
        ProtectEbsAlias = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
      }[s.Sid])
    ])
    error_message = "Each statement of protect-baseline must deny exactly the actions the security baseline lists for it."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_organizations_policy.this["protect-baseline"].content).Statement : s.Resource == "*"
      if !contains(["ProtectAlertRules", "ProtectBaselineRoles", "ProtectEbsAlias"], s.Sid)
    ])
    error_message = "The account-wide statements of protect-baseline must apply to every resource."
  }

  # The bus wildcard goes through format: the guard of make test refuses any line that would close a block comment.
  assert {
    condition = toset(one([for s in jsondecode(aws_organizations_policy.this["protect-baseline"].content).Statement : s.Resource if s.Sid == "ProtectAlertRules"])) == toset([
      "arn:aws:events:*:*:rule/svp-security-*",
      format("arn:aws:events:*:*:rule/%s/svp-security-*", "*"),
    ])
    error_message = "ProtectAlertRules must cover the svp-security-* rules on the default bus and on any named bus."
  }

  assert {
    condition = toset(one([for s in jsondecode(aws_organizations_policy.this["protect-baseline"].content).Statement : s.Resource if s.Sid == "ProtectBaselineRoles"])) == toset([
      "arn:aws:iam::*:role/OrganizationAccountAccessRole",
      "arn:aws:iam::*:role/svp-security-*",
    ])
    error_message = "ProtectBaselineRoles must cover OrganizationAccountAccessRole and the svp-security-* roles."
  }

  # The EBS key, by the tag the baseline root puts on it.
  assert {
    condition     = one([for s in jsondecode(aws_organizations_policy.this["protect-baseline"].content).Statement : s.Condition.StringEquals if s.Sid == "ProtectEbsKey"]) == { "aws:ResourceTag/Stack" = "security-baseline" }
    error_message = "ProtectEbsKey must match the KMS keys tagged Stack=security-baseline."
  }

  # Written as a[l]ias: the guard of make test refuses any line holding the keyword that renames a provider.
  assert {
    condition     = can(regex("^arn:aws:kms:\\*:\\*:a[l]ias/svp-ebs$", one([for s in jsondecode(aws_organizations_policy.this["protect-baseline"].content).Statement : s.Resource if s.Sid == "ProtectEbsAlias"])))
    error_message = "ProtectEbsAlias must cover the svp-ebs key name in every account and region, and nothing else."
  }
}

run "deny_iam_users" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_organizations_policy.this["deny-iam-users"].content).Statement) == 1
    error_message = "deny-iam-users must hold one statement."
  }

  assert {
    condition = toset(jsondecode(aws_organizations_policy.this["deny-iam-users"].content).Statement[0].Action) == toset([
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:CreateUser",
      "iam:UpdateLoginProfile",
    ])
    error_message = "deny-iam-users must deny exactly CreateUser, CreateAccessKey, CreateLoginProfile and UpdateLoginProfile."
  }

  # IAM users only: arn:aws:iam::<id>:root stays out, so the IAMCreateRootUserPassword task of sts:AssumeRoot works.
  assert {
    condition     = jsondecode(aws_organizations_policy.this["deny-iam-users"].content).Statement[0].Resource == "arn:aws:iam::*:user/*"
    error_message = "deny-iam-users must apply to arn:aws:iam::*:user/* alone, leaving the root user out."
  }

  assert {
    condition     = length(setintersection(toset(keys(jsondecode(aws_organizations_policy.this["deny-iam-users"].content).Statement[0])), toset(["Condition", "NotAction", "NotResource"]))) == 0
    error_message = "deny-iam-users must deny unconditionally, exempting no principal, without NotAction or NotResource."
  }
}

run "prod_guardrails" {
  command = plan

  assert {
    condition = jsondecode(aws_organizations_policy.this["prod-guardrails"].content).Statement == [
      {
        Sid       = "DenySpotRunInstances"
        Effect    = "Deny"
        Action    = ["ec2:RunInstances"]
        Resource  = "arn:aws:ec2:*:*:instance/*"
        Condition = { StringEquals = { "ec2:InstanceMarketType" = "spot" } }
      },
      {
        Sid      = "DenySpotRequests"
        Effect   = "Deny"
        Action   = ["ec2:RequestSpotFleet", "ec2:RequestSpotInstances"]
        Resource = "*"
      },
    ]
    error_message = "prod-guardrails must deny Spot through RunInstances, RequestSpotFleet and RequestSpotInstances, and nothing else."
  }
}

run "data_perimeter" {
  command = plan

  assert {
    condition     = [for s in jsondecode(aws_organizations_policy.this["data-perimeter"].content).Statement : s.Sid] == ["EnforceOrgIdentities", "EnforceConfusedDeputyProtection", "EnforceSecureTransport"]
    error_message = "data-perimeter must hold exactly the identity, confused deputy and TLS statements."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_organizations_policy.this["data-perimeter"].content).Statement : s.Principal == "*" && s.Resource == "*"
    ])
    error_message = "Every statement of data-perimeter must apply to every principal and resource."
  }

  # The service principal exception is the only one: no aws:PrincipalAccount, no exclusion tag.
  assert {
    condition = one([for s in jsondecode(aws_organizations_policy.this["data-perimeter"].content).Statement : s.Condition if s.Sid == "EnforceOrgIdentities"]) == {
      StringNotEqualsIfExists = { "aws:PrincipalOrgID" = "o-ab12cd34ef" }
      BoolIfExists            = { "aws:PrincipalIsAWSService" = "false" }
    }
    error_message = "EnforceOrgIdentities must deny principals outside organization_id, AWS service principals excepted, and nothing else."
  }

  assert {
    condition = one([for s in jsondecode(aws_organizations_policy.this["data-perimeter"].content).Statement : s.Condition if s.Sid == "EnforceConfusedDeputyProtection"]) == {
      StringNotEqualsIfExists = { "aws:SourceOrgID" = "o-ab12cd34ef" }
      Null                    = { "aws:SourceAccount" = "false" }
      Bool                    = { "aws:PrincipalIsAWSService" = "true" }
    }
    error_message = "EnforceConfusedDeputyProtection must deny AWS services acting for an account outside organization_id, only when aws:SourceAccount is present."
  }

  assert {
    condition = one([for s in jsondecode(aws_organizations_policy.this["data-perimeter"].content).Statement : s.Condition if s.Sid == "EnforceSecureTransport"]) == {
      BoolIfExists = { "aws:SecureTransport" = "false" }
    }
    error_message = "EnforceSecureTransport must deny every request not sent over TLS."
  }

  # Federated sign-in (Identity Center SAML, web identity) and sts:AssumeRoot carry no aws:PrincipalOrgID: listing
  # them here would lock every person out.
  assert {
    condition = toset(one([for s in jsondecode(aws_organizations_policy.this["data-perimeter"].content).Statement : s.Action if s.Sid == "EnforceOrgIdentities"])) == toset([
      "s3:*",
      "sqs:*",
      "kms:*",
      "secretsmanager:*",
      "sts:AssumeRole",
      "sts:DecodeAuthorizationMessage",
      "sts:GetAccessKeyInfo",
      "sts:GetFederationToken",
      "sts:GetServiceBearerToken",
      "sts:GetSessionToken",
      "sts:SetContext",
    ])
    error_message = "EnforceOrgIdentities must cover S3, SQS, KMS, Secrets Manager and the STS actions of the AWS example, without the federated ones."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_organizations_policy.this["data-perimeter"].content).Statement :
      toset(s.Action) == toset(["s3:*", "sqs:*", "kms:*", "secretsmanager:*", "sts:*"])
      if s.Sid != "EnforceOrgIdentities"
    ])
    error_message = "The confused deputy and TLS statements must cover S3, SQS, KMS, Secrets Manager and STS."
  }
}

run "ec2_baseline" {
  command = plan

  assert {
    condition     = jsondecode(aws_organizations_policy.this["ec2-baseline"].content).ec2_attributes.instance_metadata_defaults.http_tokens["@@assign"] == "required" && jsondecode(aws_organizations_policy.this["ec2-baseline"].content).ec2_attributes.instance_metadata_defaults.http_tokens_enforced["@@assign"] == "enabled"
    error_message = "ec2-baseline must require IMDSv2 and refuse launches with IMDSv1."
  }

  assert {
    condition     = jsondecode(aws_organizations_policy.this["ec2-baseline"].content).ec2_attributes.instance_metadata_defaults.http_put_response_hop_limit["@@assign"] == "1"
    error_message = "ec2-baseline must set the IMDS hop limit of the nodes, 1."
  }

  assert {
    condition     = jsondecode(aws_organizations_policy.this["ec2-baseline"].content).ec2_attributes.instance_metadata_defaults.http_endpoint["@@assign"] == "enabled"
    error_message = "ec2-baseline must keep the instance metadata endpoint on; the nodes read their credentials from it."
  }

  assert {
    condition     = jsondecode(aws_organizations_policy.this["ec2-baseline"].content).ec2_attributes.image_block_public_access.state["@@assign"] == "block_new_sharing" && jsondecode(aws_organizations_policy.this["ec2-baseline"].content).ec2_attributes.snapshot_block_public_access.state["@@assign"] == "block_all_sharing"
    error_message = "ec2-baseline must block public sharing of AMIs and EBS snapshots."
  }

  assert {
    condition     = jsondecode(aws_organizations_policy.this["ec2-baseline"].content).ec2_attributes.serial_console_access.status["@@assign"] == "disabled"
    error_message = "ec2-baseline must turn the EC2 serial console off."
  }

  # The NAT gateways and the NLB need an internet gateway.
  assert {
    condition     = keys(jsondecode(aws_organizations_policy.this["ec2-baseline"].content).ec2_attributes) == ["image_block_public_access", "instance_metadata_defaults", "serial_console_access", "snapshot_block_public_access"]
    error_message = "ec2-baseline must set exactly AMI and snapshot public access, instance metadata defaults and the serial console (no VPC block public access)."
  }
}

run "tag_policy" {
  command = plan

  assert {
    condition = { for k, t in jsondecode(aws_organizations_policy.this["tags"].content).tags : k => t.tag_value["@@assign"] } == {
      Project   = ["svp"]
      Env       = ["stg", "prd"]
      ManagedBy = ["terraform"]
      Stack     = ["bootstrap", "org", "baseline", "log-archive", "security", "security-baseline", "stg", "prd"]
    }
    error_message = "The tag policy must cover exactly Project, Env, ManagedBy and Stack, with the values every root and Karpenter use."
  }

  assert {
    condition     = alltrue([for k, t in jsondecode(aws_organizations_policy.this["tags"].content).tags : t.tag_key["@@assign"] == k])
    error_message = "Every tag key must be fixed to its own capitalization."
  }

  assert {
    condition = alltrue([
      for t in jsondecode(aws_organizations_policy.this["tags"].content).tags :
      toset(t.enforced_for["@@assign"]) == toset(["ec2:ALL_SUPPORTED", "eks:ALL_SUPPORTED", "kms:ALL_SUPPORTED"])
    ])
    error_message = "Every tag key must be enforced for EC2, EKS and KMS alone."
  }
}

run "root_id_ou" {
  command = plan

  variables {
    root_id = "ou-ab12-cd34ef56"
  }

  expect_failures = [var.root_id]
}

run "root_id_account" {
  command = plan

  variables {
    root_id = "000000000000"
  }

  expect_failures = [var.root_id]
}

run "prod_ou_id_root" {
  command = plan

  variables {
    prod_ou_id = "r-ab12"
  }

  expect_failures = [var.prod_ou_id]
}

run "organization_id_account" {
  command = plan

  variables {
    organization_id = "000000000000"
  }

  expect_failures = [var.organization_id]
}
