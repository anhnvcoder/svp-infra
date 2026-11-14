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

  # State in the bucket of aws/bootstrap, the management account's: bucket and region come from aws/backend.hcl, which
  # is not committed (the bucket name is unique per account).
  backend "s3" {
    key          = "aws/backup/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
