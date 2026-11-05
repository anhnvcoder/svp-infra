terraform {
  required_version = "~> 1.15"

  # No resource or data source of any provider here. aws is declared only because make test runs every test file
  # with a mock of it, which Terraform loads for a provider the module requires; the roots that call this module
  # configure it anyway.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
