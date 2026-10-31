terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # terraform-aws-modules/vpc 6.x needs provider 6.x; the root that calls this module pins the exact version in its lock file.
      version = "~> 6.0"
    }
  }
}
