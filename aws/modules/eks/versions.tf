terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # terraform-aws-modules/eks 21.29.0 needs 6.59 or later; the root that calls this module pins the exact version in its
      # lock file.
      version = "~> 6.59"
    }
  }
}
