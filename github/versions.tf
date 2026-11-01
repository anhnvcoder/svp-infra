terraform {
  # Matches the Terraform of the dev machine (Homebrew) and TERRAFORM_IMAGE of the Makefile. The S3 backend's
  # use_lockfile needs 1.10 or later; import blocks, used briefly to adopt an existing repository, need 1.5 or later.
  required_version = "~> 1.15"

  required_providers {
    github = {
      source = "integrations/github"
      # Exact: a provider release can change how a setting is read back, which turns into a diff on every repository.
      # Renovate proposes the next version as a pull request.
      version = "6.13.0"
    }
  }

  # The state of this root sits in the state bucket of aws/bootstrap under its own key. Bucket and region come from
  # aws/backend.hcl, which is not committed (the bucket name is unique per account):
  # AWS_PROFILE=anhnv-sso terraform init -backend-config=../aws/backend.hcl.
  backend "s3" {
    key          = "github/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
