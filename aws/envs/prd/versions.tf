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

  # Partial configuration: every setting comes from the command line at init, so the block stays the same in every env
  # root. aws/backend-<env>.hcl (written from output backend_hcl of aws/accounts/<env>, not committed) gives the
  # bucket, region and KMS key of the env's account; the second -backend-config gives the key of this root, with <env>
  # the value of local.env (main.tf):
  # AWS_PROFILE=anhnv-<env> terraform init -reconfigure -backend-config=../../backend-<env>.hcl -backend-config=key=aws/<env>/terraform.tfstate
  backend "s3" {}
}
