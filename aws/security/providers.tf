locals {
  default_tags = {
    Project   = "svp"
    ManagedBy = "terraform"
    # Session sweeps report everything tagged Project=svp except the stacks that stay between sessions, this one
    # included.
    Stack = "security"
  }
}

# The Security Tooling account, reached from the management account (AWS_PROFILE=anhnv-sso) through the role
# Organizations created in every member account. No profile or state bucket of its own lives in that account.
provider "aws" {
  region = var.region

  # A wrong TF_VAR_security_account_id stops before the first API call that writes.
  allowed_account_ids = [var.security_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.security_account_id}:role/OrganizationAccountAccessRole"
    session_name = "svp-terraform"
  }

  default_tags {
    tags = local.default_tags
  }
}

# Read only: the ARN of the log archive key, which the GuardDuty export needs in its key/<id> form.
provider "aws" {
  alias  = "log_archive"
  region = var.region

  allowed_account_ids = [var.log_archive_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.log_archive_account_id}:role/OrganizationAccountAccessRole"
    session_name = "svp-terraform"
  }

  default_tags {
    tags = local.default_tags
  }
}

# The management account itself, no role: reads the organization (id, root, its own email) and turns GuardDuty on
# there, which the management account needs before the delegated administrator can add it as a member.
provider "aws" {
  alias  = "management"
  region = var.region

  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.default_tags
  }
}
