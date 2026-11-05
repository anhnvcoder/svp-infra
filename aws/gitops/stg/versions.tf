terraform {
  # Matches the Terraform of the dev machine (Homebrew) and TERRAFORM_IMAGE of the Makefile; the S3 backend's
  # use_lockfile needs 1.10 or later.
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # The exact versions are in the lock file.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.6"
    }
  }

  # Partial configuration, as in the env roots: aws/backend-<env>.hcl gives the bucket, region and KMS key of the env's
  # account, the second -backend-config the key of this root, with <env> the value of local.env (main.tf):
  # AWS_PROFILE=anhnv-<env> terraform init -reconfigure -backend-config=../../backend-<env>.hcl -backend-config=key=aws/gitops/<env>/terraform.tfstate
  backend "s3" {}
}
