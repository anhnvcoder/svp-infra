# Rules on the default bus of each region that forward security events to the bus svp-security-events of the
# Security Tooling account. Rule and role names start with svp-security- because the baseline service control policy
# protects that prefix. Design notes: aws/modules/security-baseline/README.md.

locals {
  api_call = "AWS API Call via CloudTrail"

  # The actions the baseline service control policy denies on the detection services (GuardDuty, Security Hub, Config,
  # Access Analyzer in that order); a name two services share appears once.
  detection_sources = ["guardduty.amazonaws.com", "securityhub.amazonaws.com", "config.amazonaws.com", "access-analyzer.amazonaws.com"]
  detection_events = [
    "CreateFilter", "CreateIPSet", "DeleteDetector", "DeleteMembers", "DeletePublishingDestination",
    "DisassociateFromAdministratorAccount", "DisassociateFromMasterAccount", "DisassociateMembers", "StopMonitoringMembers",
    "UpdateDetector", "UpdateFilter", "UpdateIPSet", "UpdateMalwareScanSettings", "UpdateMemberDetectors",
    "UpdateOrganizationConfiguration", "UpdatePublishingDestination",
    "BatchDeleteAutomationRules", "BatchDisableStandards", "BatchUpdateAutomationRules", "CreateAutomationRule",
    "DeleteConfigurationPolicy", "DeleteFindingAggregator", "DisableImportFindingsForProduct", "DisableSecurityHub",
    "StartConfigurationPolicyDisassociation", "UpdateConfigurationPolicy", "UpdateFindingAggregator", "UpdateSecurityControl",
    "UpdateStandardsControl",
    "DeleteConfigurationAggregator", "DeleteConfigurationRecorder", "DeleteDeliveryChannel", "DeleteRetentionConfiguration",
    "PutConfigurationAggregator", "PutConfigurationRecorder", "PutDeliveryChannel", "StopConfigurationRecorder",
    "CreateArchiveRule", "DeleteAnalyzer", "UpdateArchiveRule",
  ]

  # JSON services answer AccessDeniedException, query services AccessDenied; EC2 alone answers
  # Client.UnauthorizedOperation.
  denied = [{ prefix = "AccessDenied" }]

  # Patterns are JSON strings and regions lists, so every rule has the same type whatever its pattern.
  rules = merge(
    {
      "svp-security-root-signin" = {
        description = "Console sign-in of the root user"
        regions     = var.root_signin_regions
        all_events  = false
        pattern = jsonencode({
          source        = ["aws.signin"]
          "detail-type" = ["AWS Console Sign In via CloudTrail"]
          detail        = { userIdentity = { type = ["Root"] } }
        })
      }
      "svp-security-trail" = {
        description = "CloudTrail stopped, deleted or changed, succeeded or denied"
        regions     = tolist(local.regions)
        all_events  = false
        pattern = jsonencode({
          "detail-type" = [local.api_call]
          detail = {
            eventSource = ["cloudtrail.amazonaws.com"]
            eventName   = ["DeleteTrail", "PutEventSelectors", "PutInsightSelectors", "StopLogging", "UpdateTrail"]
          }
        })
      }
      "svp-security-detection" = {
        description = "GuardDuty, Security Hub, Config or Access Analyzer turned off or changed"
        regions     = tolist(local.regions)
        all_events  = false
        pattern = jsonencode({
          "detail-type" = [local.api_call]
          detail = {
            eventSource = local.detection_sources
            eventName   = local.detection_events
            errorCode   = [{ exists = false }]
          }
        })
      }
      "svp-security-alert-rules" = {
        description = "A svp-security-* rule changed, disabled or deleted, succeeded or denied"
        regions     = tolist(local.regions)
        all_events  = false
        pattern = jsonencode({
          "detail-type" = [local.api_call]
          detail = {
            eventSource = ["events.amazonaws.com"]
            eventName   = ["DeleteRule", "DisableRule", "PutRule", "PutTargets", "RemoveTargets"]
            "$or" = [
              { requestParameters = { name = [{ prefix = "svp-security-" }] } },
              { requestParameters = { rule = [{ prefix = "svp-security-" }] } },
            ]
          }
        })
      }
      "svp-security-denied-iam" = {
        description = "Denied IAM user, access key, login profile or protected role change"
        regions     = [local.global_region]
        all_events  = false
        pattern = jsonencode({
          "detail-type" = [local.api_call]
          detail = {
            eventSource = ["iam.amazonaws.com"]
            eventName = [
              "CreateUser", "CreateAccessKey", "CreateLoginProfile", "UpdateLoginProfile", "AttachRolePolicy", "DeleteRole",
              "DeleteRolePermissionsBoundary", "DeleteRolePolicy", "DetachRolePolicy", "PutRolePermissionsBoundary", "PutRolePolicy",
              "TagRole", "UntagRole", "UpdateAssumeRolePolicy", "UpdateRole", "UpdateRoleDescription",
            ]
            errorCode = local.denied
          }
        })
      }
      "svp-security-denied-detection" = {
        description = "Denied change to GuardDuty, Security Hub, Config or Access Analyzer"
        regions     = tolist(local.regions)
        all_events  = false
        pattern = jsonencode({
          "detail-type" = [local.api_call]
          detail = {
            eventSource = local.detection_sources
            eventName   = local.detection_events
            errorCode   = local.denied
          }
        })
      }
      "svp-security-denied-storage" = {
        description = "Denied change to account S3 Block Public Access, EBS default encryption or the EBS key"
        regions     = tolist(local.regions)
        all_events  = false
        pattern = jsonencode({
          "detail-type" = [local.api_call]
          detail = {
            eventSource = ["s3.amazonaws.com", "ec2.amazonaws.com", "kms.amazonaws.com"]
            eventName = [
              "PutAccountPublicAccessBlock", "DeleteAccountPublicAccessBlock", "DisableEbsEncryptionByDefault",
              "ModifyEbsDefaultKmsKeyId", "ResetEbsDefaultKmsKeyId", "DisableKey", "DisableKeyRotation", "PutKeyPolicy",
              "ScheduleKeyDeletion", "TagResource", "UntagResource", "CreateAlias", "DeleteAlias", "UpdateAlias",
            ]
            errorCode = concat(local.denied, ["Client.UnauthorizedOperation"])
          }
        })
      }
    },
    { for k, v in {
      # AssumeRoot can be a read-only event, which only a rule with all management events receives.
      "svp-security-root-session" = {
        description = "Root session opened with sts:AssumeRoot"
        regions     = tolist(local.regions)
        all_events  = true
        pattern = jsonencode({
          source        = ["aws.sts"]
          "detail-type" = [local.api_call]
          detail        = { eventSource = ["sts.amazonaws.com"], eventName = ["AssumeRoot"] }
        })
      }
      "svp-security-org" = {
        description = "AWS Organizations structure, policy or root access change"
        regions     = [local.global_region]
        all_events  = false
        pattern = jsonencode({
          "detail-type" = [local.api_call]
          detail = {
            eventSource = ["organizations.amazonaws.com", "iam.amazonaws.com"]
            eventName = [
              "AttachPolicy", "CreatePolicy", "DeletePolicy", "DetachPolicy", "UpdatePolicy", "EnablePolicyType", "DisablePolicyType",
              "EnableAWSServiceAccess", "DisableAWSServiceAccess", "RegisterDelegatedAdministrator", "DeregisterDelegatedAdministrator",
              "CreateAccount", "CloseAccount", "InviteAccountToOrganization", "RemoveAccountFromOrganization", "MoveAccount",
              "CreateOrganizationalUnit", "DeleteOrganizationalUnit", "EnableOrganizationsRootCredentialsManagement",
              "DisableOrganizationsRootCredentialsManagement", "EnableOrganizationsRootSessions", "DisableOrganizationsRootSessions",
            ]
          }
        })
      }
    } : k => v if var.organization_events },
    { for k, v in {
      "svp-security-admin-iam" = {
        description = "Successful IAM change"
        regions     = [local.global_region]
        all_events  = false
        pattern = jsonencode({
          "detail-type" = [local.api_call]
          detail = {
            eventSource = ["iam.amazonaws.com"]
            eventName = [for p in ["Add", "Attach", "Create", "Deactivate", "Delete", "Detach", "Enable", "Put", "Remove", "Reset", "Set", "Update", "Upload"] :
            { prefix = p }]
            errorCode = [{ exists = false }]
          }
        })
      }
      "svp-security-admin-kms-s3" = {
        description = "Successful change to a KMS key or to the policy, encryption or retention of an S3 bucket"
        regions     = tolist(local.regions)
        all_events  = false
        pattern = jsonencode({
          "detail-type" = [local.api_call]
          detail = {
            eventSource = ["kms.amazonaws.com", "s3.amazonaws.com"]
            eventName = [
              "DisableKey", "DisableKeyRotation", "PutKeyPolicy", "ScheduleKeyDeletion", "DeleteAlias", "UpdateAlias",
              "PutBucketPolicy", "DeleteBucketPolicy", "PutBucketAcl", "PutBucketLifecycle", "DeleteBucketLifecycle", "PutBucketEncryption",
              "DeleteBucketEncryption", "PutObjectLockConfiguration", "PutBucketVersioning", "PutBucketOwnershipControls", "PutBucketLogging",
              "PutBucketPublicAccessBlock", "DeleteBucketPublicAccessBlock",
            ]
            errorCode = [{ exists = false }]
          }
        })
      }
    } : k => v if var.admin_events },
    { for k, v in {
      "svp-security-admin-sso" = {
        description = "Successful IAM Identity Center permission set or account assignment change"
        regions     = [coalesce(var.identity_center_region, local.home_region)]
        all_events  = false
        pattern = jsonencode({
          "detail-type" = [local.api_call]
          detail = {
            eventSource = ["sso.amazonaws.com"]
            eventName = [
              "AttachManagedPolicyToPermissionSet", "CreateAccountAssignment", "CreatePermissionSet", "DeleteAccountAssignment",
              "DeleteInlinePolicyFromPermissionSet", "DeletePermissionSet", "DetachManagedPolicyFromPermissionSet", "ProvisionPermissionSet",
              "PutInlinePolicyToPermissionSet", "UpdatePermissionSet",
            ]
            errorCode = [{ exists = false }]
          }
        })
      }
    } : k => v if var.identity_center_region != null },
  )

  # One entry per rule and region, keyed "<rule>/<region>".
  forward_rules = { for e in flatten([
    for name, r in local.rules : [for region in r.regions : {
      key         = "${name}/${region}"
      name        = name
      region      = region
      description = r.description
      state       = r.all_events ? "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS" : "ENABLED"
      pattern     = r.pattern
    }]
  ]) : e.key => e }
}

################################################################################
# Forwarding role
################################################################################

# EventBridge needs a role to put events on a bus of another account.
data "aws_iam_policy_document" "forwarder_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "forwarder" {
  name               = "svp-security-forwarder"
  description        = "EventBridge: forwards svp-security-* events to the security event bus"
  assume_role_policy = data.aws_iam_policy_document.forwarder_trust.json
}

data "aws_iam_policy_document" "forwarder" {
  statement {
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = [var.security_event_bus_arn]
  }
}

resource "aws_iam_role_policy" "forwarder" {
  name   = "put-security-events"
  role   = aws_iam_role.forwarder.id
  policy = data.aws_iam_policy_document.forwarder.json
}

################################################################################
# Rules
################################################################################

resource "aws_cloudwatch_event_rule" "forward" {
  for_each = local.forward_rules

  region        = each.value.region
  name          = each.value.name
  description   = each.value.description
  event_pattern = each.value.pattern
  state         = each.value.state
}

resource "aws_cloudwatch_event_target" "forward" {
  for_each = local.forward_rules

  region    = each.value.region
  rule      = aws_cloudwatch_event_rule.forward[each.key].name
  target_id = "svp-security-events"
  arn       = var.security_event_bus_arn
  role_arn  = aws_iam_role.forwarder.arn

  # The role must be able to put events before the first event arrives.
  depends_on = [aws_iam_role_policy.forwarder]
}
