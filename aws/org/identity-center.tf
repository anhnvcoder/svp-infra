# The organization instance of IAM Identity Center, owned by the management account. Its existing permission sets
# (those of the management account itself) are not managed here.
data "aws_ssoadmin_instances" "this" {
  provider = aws.sso

  lifecycle {
    postcondition {
      condition     = length(self.arns) == 1
      error_message = "Expected exactly one IAM Identity Center instance in sso_region; check sso_region against the SSO profile."
    }
  }
}

locals {
  sso_instance_arn  = one(data.aws_ssoadmin_instances.this.arns)
  identity_store_id = one(data.aws_ssoadmin_instances.this.identity_store_ids)
}

data "aws_identitystore_user" "learner" {
  provider = aws.sso

  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = var.sso_user_name
    }
  }
}

data "aws_partition" "current" {}

resource "aws_ssoadmin_permission_set" "admin" {
  provider = aws.sso

  name         = "SvpAdmin"
  description  = "Administrator of the svp member accounts"
  instance_arn = local.sso_instance_arn
  # Longer than one AWS session of the lab, short enough that a forgotten terminal does not stay signed in for the day.
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "admin" {
  provider = aws.sso

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  managed_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

# Assigning the permission set provisions it into the account; the policy is attached first so the role IAM Identity
# Center creates there (AWSReservedSSO_SvpAdmin_...) carries it from the start.
resource "aws_ssoadmin_account_assignment" "learner" {
  provider = aws.sso
  for_each = local.member_envs

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  principal_id       = data.aws_identitystore_user.learner.user_id
  principal_type     = "USER"
  target_id          = aws_organizations_account.member[each.key].id
  target_type        = "AWS_ACCOUNT"

  depends_on = [aws_ssoadmin_managed_policy_attachment.admin]
}
