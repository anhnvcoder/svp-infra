provider "aws" {
  region = var.region

  # The provider refuses to touch any other account, so a wrong AWS_PROFILE stops before the first API call that
  # writes. The account is the env's own: profile anhnv-<env>, and TF_VAR_account_id set in the command from
  # SVP_AWS_<ENV>_ACCOUNT_ID, the variable the learner exports in the session's terminal (never in a committed file).
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "svp"
      Env       = local.env
      ManagedBy = "terraform"
      # Session sweeps report everything tagged Project=svp; Stack tells which root left it behind.
      Stack = local.env
    }
  }
}

# CloudFront takes a web ACL of AWS WAF only from us-east-1: the waf module runs with this provider, same account,
# same tags.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "svp"
      Env       = local.env
      ManagedBy = "terraform"
      Stack     = local.env
    }
  }
}
