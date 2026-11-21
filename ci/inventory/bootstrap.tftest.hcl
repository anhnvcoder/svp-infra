# Plan of aws/bootstrap on an empty management account.

mock_provider "aws" {}

variables {
  account_id = "000000000000"
}

run "inventory" {
  command = plan
}
