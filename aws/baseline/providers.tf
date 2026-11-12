locals {
  default_tags = {
    Project   = "svp"
    ManagedBy = "terraform"
    # The baseline service control policy protects the EBS keys by this tag. Session sweeps report everything tagged
    # Project=svp except the stacks that stay between sessions, this one included.
    Stack = "security-baseline"
  }
}

# One provider per account, all in the home region: Terraform cannot loop over providers, so the five are written out.
# The management account itself, no role (AWS_PROFILE=anhnv-sso).
provider "aws" {
  alias  = "mgmt"
  region = var.region

  # A wrong AWS_PROFILE or TF_VAR_account_id stops before the first API call that writes.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.default_tags
  }
}

# The member accounts, reached through the role Organizations created in each of them. No profile or state bucket of
# this root lives in them; the baseline service control policy exempts this role alone.
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

provider "aws" {
  alias  = "security"
  region = var.region

  allowed_account_ids = [var.security_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.security_account_id}:role/OrganizationAccountAccessRole"
    session_name = "svp-terraform"
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "stg"
  region = var.region

  allowed_account_ids = [var.stg_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.stg_account_id}:role/OrganizationAccountAccessRole"
    session_name = "svp-terraform"
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "prd"
  region = var.region

  allowed_account_ids = [var.prd_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.prd_account_id}:role/OrganizationAccountAccessRole"
    session_name = "svp-terraform"
  }

  default_tags {
    tags = local.default_tags
  }
}
