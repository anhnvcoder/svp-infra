terraform {
  # Matches the Terraform of the dev machine (Homebrew) and TERRAFORM_IMAGE of the Makefile; the S3 backend's
  # use_lockfile needs 1.10 or later.
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # The X-Ray resources of modules/observability need 6.46 or later; the exact version is in the lock file.
      version = "~> 6.46"
    }
  }

  # The state of this root lives in the bucket it creates. The first apply runs on local state (a local_override.tf
  # with backend "local" replaces this block); the state then moves here with
  # init -migrate-state -backend-config=../../backend-prd.hcl, the file written from the backend_hcl output (bucket,
  # region, KMS key; not committed). README.md of aws/accounts.
  backend "s3" {
    key          = "aws/accounts/prd/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
