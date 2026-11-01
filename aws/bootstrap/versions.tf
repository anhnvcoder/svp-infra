terraform {
  # Matches the Terraform of the dev machine (Homebrew) and TERRAFORM_IMAGE of the Makefile; the S3 backend's
  # use_lockfile needs 1.10 or later.
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # The state of this root lives in the bucket it creates. The first apply runs on local state (a local_override.tf
  # with backend "local" replaces this block); the state then moves here with init -migrate-state. Bucket and region
  # come from aws/backend.hcl, which is not committed: the bucket name is unique per account.
  backend "s3" {
    key          = "aws/bootstrap/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
