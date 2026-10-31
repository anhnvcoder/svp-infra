provider "aws" {
  region = var.region

  # The provider refuses to touch any other account, so a wrong AWS_PROFILE stops before the first API call that
  # writes. The account id comes from TF_VAR_account_id, never from a committed file.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "svp"
      ManagedBy = "terraform"
      # Session sweeps report everything tagged Project=svp except this stack, which stays between sessions.
      Stack = "bootstrap"
    }
  }
}
