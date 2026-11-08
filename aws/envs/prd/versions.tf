terraform {
  # Matches the Terraform of the dev machine (Homebrew) and TERRAFORM_IMAGE of the Makefile; the S3 backend's
  # use_lockfile needs 1.10 or later.
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_pricingplanmanager_subscription (modules/media) needs 6.69 or later; the exact version is in the lock file.
      version = "~> 6.69"
    }
  }

  # Partial configuration: every setting comes from the command line at init, so the block is the same in every env
  # root. aws/backend-<env>.hcl (from output backend_hcl of aws/accounts/<env>, not committed) gives the bucket, region
  # and KMS key; the second -backend-config gives the key of this root, with <env> the value of local.env (main.tf):
  # AWS_PROFILE=anhnv-<env> terraform init -reconfigure -backend-config=../../backend-<env>.hcl -backend-config=key=aws/<env>/terraform.tfstate
  backend "s3" {}
}
