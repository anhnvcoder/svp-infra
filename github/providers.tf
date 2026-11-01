# The token comes from the GITHUB_TOKEN environment variable (GITHUB_TOKEN=$(gh auth token)), never from a file. It
# must be an admin of every repository in local.repositories; no AWS provider here, so no account pin or default tags apply.
provider "github" {
  owner = "anhnvcoder"
}
