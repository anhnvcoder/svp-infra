terraform {
  # Matches the Terraform of the dev machine (Homebrew) and TERRAFORM_IMAGE of the Makefile; the S3 backend's
  # use_lockfile needs 1.10 or later.
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # terraform-aws-modules/eks 21.29.0 (inside modules/eks) needs 6.59 or later; the exact version is in the lock file.
      version = "~> 6.59"
    }
  }

  # One state and one lock per env: this key belongs to stg alone. Bucket and region come from aws/backend.hcl, which
  # is not committed (the bucket name is unique per account):
  # AWS_PROFILE=anhnv-sso terraform init -backend-config=../../backend.hcl.
  backend "s3" {
    key          = "aws/stg/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
