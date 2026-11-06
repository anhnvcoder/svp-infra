locals {
  # The only regions a workload account may use: ap-southeast-1 for everything that runs, us-east-1 for what AWS serves
  # from there alone (the ACM certificate and the WAF web ACL of CloudFront, IAM Identity Center of this organization).
  allowed_regions = ["ap-southeast-1", "us-east-1"]

  # Global services, and the few global calls of regional services, whose requests carry us-east-1 or another region
  # no matter where the caller works: denying them by region would break IAM, Organizations, Route 53, CloudFront,
  # WAF for CloudFront, Budgets, STS, Support, IAM Identity Center and the console. Verbatim the NotAction list of
  # the AWS example "Deny access to AWS based on the requested AWS Region"
  # (https://docs.aws.amazon.com/controltower/latest/controlreference/primary-region-deny-policy.html, read
  # 2026-11-05; the same example is in the AWS Organizations user guide, "Example SCPs: general").
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

  # Deny-only policies: the FullAWSAccess policy AWS attaches to every root, OU and account keeps granting what IAM
  # allows, and these take away what no workload account may do whatever its IAM says. No principal is exempted: the
  # one way around them is to act from the management account, which service control policies never reach.
  policies = {
    # A member account that leaves takes itself out of every policy and out of the organization trail.
    "deny-leave-organization" = {
      description = "Workload accounts cannot leave the organization."
      statements = [
        {
          Sid      = "DenyLeaveOrganization"
          Effect   = "Deny"
          Action   = ["organizations:LeaveOrganization"]
          Resource = "*"
        },
      ]
    }

    # The organization trail lives in the management account, which a member account cannot change; this also keeps a
    # member account from turning off or reshaping any trail of its own.
    "protect-cloudtrail" = {
      description = "Workload accounts cannot stop, delete or change CloudTrail trails."
      statements = [
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
    }

    # Resources in a region nobody watches cost money unseen; the session sweep reads only the two allowed regions.
    "deny-other-regions" = {
      description = "Workload accounts can use only ap-southeast-1 and us-east-1, global services aside."
      statements = [
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
    }
  }
}

resource "aws_organizations_policy" "this" {
  for_each = local.policies

  name        = "svp-${each.key}"
  description = each.value.description
  type        = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version   = "2012-10-17"
    Statement = each.value.statements
  })
}

# Keyed by the static map of policies, not by the policies themselves: their keys must be known before any policy exists
# (a first apply, or an import into the root that calls this module).
resource "aws_organizations_policy_attachment" "this" {
  for_each = local.policies

  policy_id = aws_organizations_policy.this[each.key].id
  target_id = var.target_id
}
