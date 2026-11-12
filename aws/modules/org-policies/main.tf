locals {
  # The only regions a member account may use: ap-southeast-1 for everything that runs, us-east-1 for what AWS serves
  # from there alone (the ACM certificate and the WAF web ACL of CloudFront, IAM Identity Center of this organization).
  allowed_regions = ["ap-southeast-1", "us-east-1"]

  # Global services, and the few global calls of regional services, whose requests carry us-east-1 or another region no
  # matter where the caller works: denying them by region would break IAM, Organizations, Route 53, CloudFront, WAF for
  # CloudFront, Budgets, STS, Support, IAM Identity Center and the console. Verbatim the NotAction list of
  # https://docs.aws.amazon.com/controltower/latest/controlreference/primary-region-deny-policy.html
  global_actions = [
    "a4b:*",
    "access-analyzer:*",
    "account:*",
    "acm:*",
    "activate:*",
    "artifact:*",
    "aws-marketplace-management:*",
    "aws-marketplace:*",
    "aws-portal:*",
    "billing:*",
    "billingconductor:*",
    "budgets:*",
    "ce:*",
    "chatbot:*",
    "chime:*",
    "cloudfront:*",
    "cloudtrail:LookupEvents",
    "compute-optimizer:*",
    "config:*",
    "consoleapp:*",
    "consolidatedbilling:*",
    "cur:*",
    "datapipeline:GetAccountLimits",
    "devicefarm:*",
    "directconnect:*",
    "ec2:DescribeRegions",
    "ec2:DescribeTransitGateways",
    "ec2:DescribeVpnGateways",
    "ecr-public:*",
    "fms:*",
    "freetier:*",
    "globalaccelerator:*",
    "health:*",
    "iam:*",
    "importexport:*",
    "invoicing:*",
    "iq:*",
    "kms:*",
    "license-manager:ListReceivedLicenses",
    "lightsail:Get*",
    "mobileanalytics:*",
    "networkmanager:*",
    "notifications-contacts:*",
    "notifications:*",
    "organizations:*",
    "payments:*",
    "pricing:*",
    "quicksight:DescribeAccountSubscription",
    "resource-explorer-2:*",
    "route53-recovery-cluster:*",
    "route53-recovery-control-config:*",
    "route53-recovery-readiness:*",
    "route53:*",
    "route53domains:*",
    "s3:CreateMultiRegionAccessPoint",
    "s3:DeleteMultiRegionAccessPoint",
    "s3:DescribeMultiRegionAccessPointOperation",
    "s3:GetAccountPublicAccessBlock",
    "s3:GetBucketLocation",
    "s3:GetBucketPolicyStatus",
    "s3:GetBucketPublicAccessBlock",
    "s3:GetMultiRegionAccessPoint",
    "s3:GetMultiRegionAccessPointPolicy",
    "s3:GetMultiRegionAccessPointPolicyStatus",
    "s3:GetStorageLensConfiguration",
    "s3:GetStorageLensDashboard",
    "s3:ListAllMyBuckets",
    "s3:ListMultiRegionAccessPoints",
    "s3:ListStorageLensConfigurations",
    "s3:PutAccountPublicAccessBlock",
    "s3:PutMultiRegionAccessPointPolicy",
    "savingsplans:*",
    "shield:*",
    "sso:*",
    "sts:*",
    "support:*",
    "supportapp:*",
    "supportplans:*",
    "sustainability:*",
    "tag:GetResources",
    "tax:*",
    "trustedadvisor:*",
    "vendor-insights:ListEntitledSecurityProfiles",
    "waf-regional:*",
    "waf:*",
    "wafv2:*",
  ]

  # The one principal exempted from protect-baseline: the role Organizations creates in each member account, which only
  # the management account can assume, and which the baseline roots of this repository apply through.
  baseline_deployer_arn = "arn:aws:iam::*:role/OrganizationAccountAccessRole"

  baseline_exemption = {
    ArnNotLike = {
      "aws:PrincipalARN" = local.baseline_deployer_arn
    }
  }

  # Services the resource control policy covers, the ones the lab keeps data or credentials in.
  rcp_actions = ["s3:*", "sqs:*", "kms:*", "secretsmanager:*", "sts:*"]

  # Same values for every tag key: changing a tag of these types to a value outside the list is refused, every other
  # type only reports compliance.
  tag_enforced_for = ["ec2:ALL_SUPPORTED", "eks:ALL_SUPPORTED", "kms:ALL_SUPPORTED"]

  # Every policy of the organization, by key, with its type and the one target it is attached to. Service and resource
  # control policies are deny-only: FullAWSAccess and RCPFullAWSAccess, which AWS attaches to every root, OU and
  # account, keep granting what IAM allows, and these take away what no member account may do whatever its IAM says.
  # Neither type reaches the management account; declarative and tag policies do. Design notes: README.md
  policies = {
    # A member account that leaves takes itself out of every policy and out of the organization trail.
    "deny-leave-organization" = {
      type        = "SERVICE_CONTROL_POLICY"
      target_id   = var.root_id
      description = "Member accounts cannot leave the organization."
      content = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "DenyLeaveOrganization"
            Effect   = "Deny"
            Action   = ["organizations:LeaveOrganization"]
            Resource = "*"
          },
        ]
      })
    }

    # The organization trail lives in the management account, which a member account cannot change; this also keeps a
    # member account from turning off or reshaping any trail of its own.
    "protect-cloudtrail" = {
      type        = "SERVICE_CONTROL_POLICY"
      target_id   = var.root_id
      description = "Member accounts cannot stop, delete or change CloudTrail trails."
      content = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenyCloudTrailChanges"
            Effect = "Deny"
            Action = [
              "cloudtrail:DeleteTrail",
              "cloudtrail:PutEventSelectors",
              "cloudtrail:PutInsightSelectors",
              "cloudtrail:StopLogging",
              "cloudtrail:UpdateTrail",
            ]
            Resource = "*"
          },
        ]
      })
    }

    # Resources in a region nobody watches cost money unseen; the session sweep reads only the two allowed regions.
    "deny-other-regions" = {
      type        = "SERVICE_CONTROL_POLICY"
      target_id   = var.root_id
      description = "Member accounts can use only ap-southeast-1 and us-east-1, global services aside."
      content = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid       = "DenyOtherRegions"
            Effect    = "Deny"
            NotAction = local.global_actions
            Resource  = "*"
            Condition = {
              StringNotEquals = {
                "aws:RequestedRegion" = local.allowed_regions
              }
            }
          },
        ]
      })
    }

    # The security baseline (account public access block, default EBS encryption and its key, Config, GuardDuty,
    # Security Hub, Access Analyzer, the alert rules and their roles) changes only through Terraform run from the
    # management account. Creating and deleting malware protection plans, flow logs and WAF logging stay open: every
    # session creates and removes them.
    "protect-baseline" = {
      type        = "SERVICE_CONTROL_POLICY"
      target_id   = var.root_id
      description = "Only OrganizationAccountAccessRole can change the security baseline of a member account."
      content = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid       = "ProtectAccountPublicAccessBlock"
            Effect    = "Deny"
            Action    = ["s3:PutAccountPublicAccessBlock"]
            Resource  = "*"
            Condition = local.baseline_exemption
          },
          {
            Sid    = "ProtectEbsDefaultEncryption"
            Effect = "Deny"
            Action = [
              "ec2:DisableEbsEncryptionByDefault",
              "ec2:ModifyEbsDefaultKmsKeyId",
              "ec2:ResetEbsDefaultKmsKeyId",
            ]
            Resource  = "*"
            Condition = local.baseline_exemption
          },
          {
            Sid    = "ProtectConfig"
            Effect = "Deny"
            Action = [
              "config:DeleteConfigurationAggregator",
              "config:DeleteConfigurationRecorder",
              "config:DeleteDeliveryChannel",
              "config:DeleteRetentionConfiguration",
              "config:PutConfigurationAggregator",
              "config:PutConfigurationRecorder",
              "config:PutDeliveryChannel",
              "config:StopConfigurationRecorder",
            ]
            Resource  = "*"
            Condition = local.baseline_exemption
          },
          {
            Sid    = "ProtectGuardDuty"
            Effect = "Deny"
            Action = [
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
            Resource  = "*"
            Condition = local.baseline_exemption
          },
          {
            Sid    = "ProtectSecurityHub"
            Effect = "Deny"
            Action = [
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
            Resource  = "*"
            Condition = local.baseline_exemption
          },
          {
            Sid    = "ProtectAccessAnalyzer"
            Effect = "Deny"
            Action = [
              "access-analyzer:CreateArchiveRule",
              "access-analyzer:DeleteAnalyzer",
              "access-analyzer:UpdateArchiveRule",
            ]
            Resource  = "*"
            Condition = local.baseline_exemption
          },
          {
            Sid    = "ProtectAlertRules"
            Effect = "Deny"
            Action = [
              "events:DeleteRule",
              "events:DisableRule",
              "events:PutRule",
              "events:PutTargets",
              "events:RemoveTargets",
            ]
            # The second form is a rule on a named event bus.
            Resource = [
              "arn:aws:events:*:*:rule/svp-security-*",
              "arn:aws:events:*:*:rule/*/svp-security-*",
            ]
            Condition = local.baseline_exemption
          },
          {
            Sid    = "ProtectBaselineRoles"
            Effect = "Deny"
            Action = [
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
            Resource = [
              "arn:aws:iam::*:role/OrganizationAccountAccessRole",
              "arn:aws:iam::*:role/svp-security-*",
            ]
            Condition = local.baseline_exemption
          },
          {
            # The EBS key is found by the tag the baseline root puts on it; untagging is denied too, or untag then
            # delete would get around this statement.
            Sid    = "ProtectEbsKey"
            Effect = "Deny"
            Action = [
              "kms:DisableKey",
              "kms:DisableKeyRotation",
              "kms:PutKeyPolicy",
              "kms:ScheduleKeyDeletion",
              "kms:TagResource",
              "kms:UntagResource",
            ]
            Resource = "*"
            Condition = merge(local.baseline_exemption, {
              StringEquals = {
                "aws:ResourceTag/Stack" = "security-baseline"
              }
            })
          },
          {
            Sid    = "ProtectEbsAlias"
            Effect = "Deny"
            Action = [
              "kms:CreateAlias",
              "kms:DeleteAlias",
              "kms:UpdateAlias",
            ]
            Resource  = "arn:aws:kms:*:*:alias/svp-ebs"
            Condition = local.baseline_exemption
          },
        ]
      })
    }

    # No principal is exempted. The resource stops short of arn:aws:iam::<id>:root, so the IAMCreateRootUserPassword
    # task of sts:AssumeRoot still works on a member account.
    "deny-iam-users" = {
      type        = "SERVICE_CONTROL_POLICY"
      target_id   = var.root_id
      description = "Member accounts cannot create IAM users, their access keys or console passwords."
      content = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenyIamUsers"
            Effect = "Deny"
            Action = [
              "iam:CreateAccessKey",
              "iam:CreateLoginProfile",
              "iam:CreateUser",
              "iam:UpdateLoginProfile",
            ]
            Resource = "arn:aws:iam::*:user/*"
          },
        ]
      })
    }

    # Spot capacity can be taken back at two minutes' notice. ec2:CreateFleet (Karpenter) carries no
    # ec2:InstanceMarketType for instances, so the on-demand NodePool of prd stays the guard there.
    "prod-guardrails" = {
      type        = "SERVICE_CONTROL_POLICY"
      target_id   = var.prod_ou_id
      description = "Production accounts cannot launch Spot instances."
      content = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "DenySpotRunInstances"
            Effect   = "Deny"
            Action   = ["ec2:RunInstances"]
            Resource = "arn:aws:ec2:*:*:instance/*"
            Condition = {
              StringEquals = {
                "ec2:InstanceMarketType" = "spot"
              }
            }
          },
          {
            Sid    = "DenySpotRequests"
            Effect = "Deny"
            Action = [
              "ec2:RequestSpotFleet",
              "ec2:RequestSpotInstances",
            ]
            Resource = "*"
          },
        ]
      })
    }

    # Identity perimeter of the AWS data perimeter examples, without their per-sample exceptions, plus TLS only.
    # Federated sign-in (AssumeRoleWithSAML, AssumeRoleWithWebIdentity) carries no aws:PrincipalOrgID, so it stays out
    # of the first statement.
    "data-perimeter" = {
      type        = "RESOURCE_CONTROL_POLICY"
      target_id   = var.root_id
      description = "S3, SQS, KMS, Secrets Manager and STS of member accounts serve only this organization, over TLS."
      content = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid       = "EnforceOrgIdentities"
            Effect    = "Deny"
            Principal = "*"
            Action = [
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
            ]
            Resource = "*"
            Condition = {
              StringNotEqualsIfExists = {
                "aws:PrincipalOrgID" = var.organization_id
              }
              BoolIfExists = {
                "aws:PrincipalIsAWSService" = "false"
              }
            }
          },
          {
            # Only a service acting for an account (aws:SourceAccount present) is checked: a service principal that
            # acts for no account, such as ec2.amazonaws.com assuming a role, carries no source to compare.
            Sid       = "EnforceConfusedDeputyProtection"
            Effect    = "Deny"
            Principal = "*"
            Action    = local.rcp_actions
            Resource  = "*"
            Condition = {
              StringNotEqualsIfExists = {
                "aws:SourceOrgID" = var.organization_id
              }
              Null = {
                "aws:SourceAccount" = "false"
              }
              Bool = {
                "aws:PrincipalIsAWSService" = "true"
              }
            }
          },
          {
            Sid       = "EnforceSecureTransport"
            Effect    = "Deny"
            Principal = "*"
            Action    = local.rcp_actions
            Resource  = "*"
            Condition = {
              BoolIfExists = {
                "aws:SecureTransport" = "false"
              }
            }
          },
        ]
      })
    }

    # Hop limit 1 is what the EKS nodes, Karpenter nodes and the bastion already use. Public VPCs stay allowed: the NAT
    # gateways and the NLB need an internet gateway.
    "ec2-baseline" = {
      type        = "DECLARATIVE_POLICY_EC2"
      target_id   = var.root_id
      description = "IMDSv2 only, no public AMI or EBS snapshot sharing, no EC2 serial console."
      content = jsonencode({
        ec2_attributes = {
          image_block_public_access = {
            state = { "@@assign" = "block_new_sharing" }
          }
          snapshot_block_public_access = {
            state = { "@@assign" = "block_all_sharing" }
          }
          instance_metadata_defaults = {
            http_tokens                 = { "@@assign" = "required" }
            http_put_response_hop_limit = { "@@assign" = "1" }
            http_endpoint               = { "@@assign" = "enabled" }
            http_tokens_enforced        = { "@@assign" = "enabled" }
          }
          serial_console_access = {
            status = { "@@assign" = "disabled" }
          }
        }
      })
    }

    # A tag policy cannot make a tag mandatory; it fixes the case of each key and the values it may take.
    "tags" = {
      type        = "TAG_POLICY"
      target_id   = var.root_id
      description = "Case and allowed values of the Project, Env, ManagedBy and Stack tags."
      content = jsonencode({
        tags = {
          Project = {
            tag_key      = { "@@assign" = "Project" }
            tag_value    = { "@@assign" = ["svp"] }
            enforced_for = { "@@assign" = local.tag_enforced_for }
          }
          Env = {
            tag_key      = { "@@assign" = "Env" }
            tag_value    = { "@@assign" = ["stg", "prd"] }
            enforced_for = { "@@assign" = local.tag_enforced_for }
          }
          ManagedBy = {
            tag_key      = { "@@assign" = "ManagedBy" }
            tag_value    = { "@@assign" = ["terraform"] }
            enforced_for = { "@@assign" = local.tag_enforced_for }
          }
          Stack = {
            tag_key = { "@@assign" = "Stack" }
            tag_value = {
              "@@assign" = ["bootstrap", "org", "baseline", "log-archive", "security", "security-baseline", "stg", "prd"]
            }
            enforced_for = { "@@assign" = local.tag_enforced_for }
          }
        }
      })
    }
  }
}

resource "aws_organizations_policy" "this" {
  for_each = local.policies

  name        = "svp-${each.key}"
  description = each.value.description
  type        = each.value.type
  content     = each.value.content
}

# Keyed by the static map of policies, not by the policies themselves: their keys must be known before any policy exists
# (a first apply, or an import into the root that calls this module). One target per policy, so none is attached twice.
resource "aws_organizations_policy_attachment" "this" {
  for_each = local.policies

  policy_id = aws_organizations_policy.this[each.key].id
  target_id = each.value.target_id
}
