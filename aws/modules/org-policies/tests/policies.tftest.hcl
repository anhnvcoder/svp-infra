# Content of the three service control policies, read back from the JSON the module sends to Organizations, and the
# validation of target_id. The AWS provider is a mock: nothing reaches an account; the module reads no data source.

mock_provider "aws" {}

variables {
  target_id = "ou-ab12-cd34ef56"
}

run "policies" {
  command = plan

  assert {
    condition     = toset(keys(aws_organizations_policy.this)) == toset(["deny-leave-organization", "protect-cloudtrail", "deny-other-regions"])
    error_message = "The module must create exactly the three service control policies."
  }

  assert {
    condition     = alltrue([for p in aws_organizations_policy.this : p.type == "SERVICE_CONTROL_POLICY" && startswith(p.name, "svp-")])
    error_message = "Every policy must be a service control policy named svp-<key>."
  }

  # The size limit of a service control policy (AWS Organizations quotas); jsonencode writes no whitespace.
  assert {
    condition     = alltrue([for p in aws_organizations_policy.this : length(p.content) <= 10240])
    error_message = "A service control policy must fit in 10,240 characters."
  }

  # Deny-only: an Allow here would add nothing to FullAWSAccess and could only widen what a reader thinks is granted.
  assert {
    condition     = alltrue(flatten([for p in aws_organizations_policy.this : [for s in jsondecode(p.content).Statement : s.Effect == "Deny"]]))
    error_message = "Every statement of every policy must be a Deny."
  }

  assert {
    condition     = alltrue([for p in aws_organizations_policy.this : jsondecode(p.content).Version == "2012-10-17"])
    error_message = "Every policy must use policy language version 2012-10-17."
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

  assert {
    condition     = toset(keys(aws_organizations_policy_attachment.this)) == toset(keys(aws_organizations_policy.this))
    error_message = "Every policy must be attached."
  }

  assert {
    condition     = alltrue([for a in aws_organizations_policy_attachment.this : a.target_id == "ou-ab12-cd34ef56"])
    error_message = "Every policy must be attached to target_id."
  }
}

run "target_id_root" {
  command = plan

  variables {
    target_id = "r-ab12"
  }

  expect_failures = [var.target_id]
}

run "target_id_account" {
  command = plan

  variables {
    target_id = "000000000000"
  }

  expect_failures = [var.target_id]
}
