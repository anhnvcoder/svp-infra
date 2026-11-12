# The only provider: the log archive account, reached from the management account (AWS_PROFILE=anhnv-sso) through the
# role Organizations created in every member account. No profile or state bucket of its own lives in that account.
provider "aws" {
  region = var.region

  # A wrong TF_VAR_log_archive_account_id stops before the first API call that writes.
  allowed_account_ids = [var.log_archive_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.log_archive_account_id}:role/OrganizationAccountAccessRole"
    session_name = "svp-terraform"
  }

  default_tags {
    tags = {
      Project   = "svp"
      ManagedBy = "terraform"
      # Session sweeps report everything tagged Project=svp except the stacks that stay between sessions, like this one.
      Stack = "log-archive"
    }
  }
}
