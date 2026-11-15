provider "aws" {
  region = var.region

  # The provider refuses to touch any other account, so a wrong AWS_PROFILE stops before the first API call that
  # writes. The account id comes from TF_VAR_account_id, never from a committed file.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "svp"
      Env       = local.env
      ManagedBy = "terraform"
      # Session sweeps keep everything tagged Stack=baseline: it stays between sessions, except what a `session` flag
      # of paid-features.json makes (it carries the tag too, but sweep.sh reports it as left over).
      Stack = "baseline"
    }
  }
}
