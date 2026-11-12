locals {
  # Every provider of this root carries the same guard and tags.
  default_tags = {
    Project   = "svp"
    ManagedBy = "terraform"
    # Session sweeps report everything tagged Project=svp except the stacks that stay between sessions, this one included.
    Stack = "org"
  }
}

# Organizations (a global service the provider reaches through its own endpoint), the organization trail and the key and
# buckets it wrote to before the log archive account.
provider "aws" {
  region = var.region

  # The provider refuses to touch any other account, so a wrong AWS_PROFILE stops before the first API call that
  # writes. The management account id comes from TF_VAR_account_id, never from a committed file.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.default_tags
  }
}

# IAM Identity Center answers only in the region of its instance.
provider "aws" {
  alias  = "sso"
  region = var.sso_region

  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.default_tags
  }
}

# Read only: the ARN of the log archive key, which the trail needs in its key/<id> form. The account comes from the
# state, not from a variable, so the first apply that only creates the accounts (-target) never configures this one.
provider "aws" {
  alias  = "log_archive"
  region = var.region

  allowed_account_ids = [aws_organizations_account.log_archive.id]

  assume_role {
    role_arn     = "arn:aws:iam::${aws_organizations_account.log_archive.id}:role/OrganizationAccountAccessRole"
    session_name = "svp-terraform"
  }

  default_tags {
    tags = local.default_tags
  }
}
