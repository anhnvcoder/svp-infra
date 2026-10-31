# tflint configuration of every directory `make tflint` checks (the Makefile passes --config with this file).

# Local modules are inspected with the values their caller passes; modules from the registry are checked by their
# authors, and by trivy here.
config {
  call_module_type = "local"
}

# Bundled with tflint: syntax and conventions (required versions, unused declarations, deprecated syntax).
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Rules of the AWS provider (invalid instance types, names, regions). Pinned: a new release adds rules, so it is
# taken in a Renovate pull request, not on the next run. deep_check stays off: it calls the AWS API.
plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
