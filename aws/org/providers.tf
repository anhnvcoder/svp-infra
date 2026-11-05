locals {
  # Every provider of this root carries the same guard and tags.
  default_tags = {
    Project   = "svp"
    ManagedBy = "terraform"
    # Session sweeps report everything tagged Project=svp except the stacks that stay between sessions, this one included.
    Stack = "org"
  }
}

# Organizations (a global service the provider reaches through its own endpoint), the organization trail, its key and
# its buckets.
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
