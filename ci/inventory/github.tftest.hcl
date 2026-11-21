# Plan of github/ on repositories that exist with none of these settings yet: the provider is a mock, no token.

mock_provider "github" {
  mock_data "github_user" {
    defaults = {
      id = "1"
    }
  }
}

run "inventory" {
  command = plan
}
