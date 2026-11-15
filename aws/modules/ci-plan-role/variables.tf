variable "env" {
  description = "Environment of the account (stg, prd): picks the two state keys the role may read and the media bucket svp-<env>-media-<account>-<region>."
  type        = string

  validation {
    condition     = contains(["stg", "prd"], var.env)
    error_message = "env must be stg or prd."
  }
}

variable "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider of GitHub Actions in this account (github_oidc_provider_arn of the registry module): the only principal the trust accepts."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be the ARN of the IAM OIDC provider token.actions.githubusercontent.com of an account."
  }
}

variable "subject" {
  description = "The one sub claim the trust accepts, in the immutable form of a job that names an environment: repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<name>."
  type        = string

  # Only an environment: its required reviewer approves each run, which a branch or pull request claim would skip.
  validation {
    condition     = can(regex("^repo:[A-Za-z0-9-]+@[0-9]+/[A-Za-z0-9._-]+@[0-9]+:environment:[A-Za-z0-9._-]+$", var.subject))
    error_message = "subject must be one GitHub OIDC sub claim without wildcards: repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<name>."
  }
}

variable "state_bucket" {
  description = "Bucket of the Terraform state of this account, svp-tfstate-<account>-<region> (state_bucket of the account-baseline module): the role reads two of its keys and writes nothing in it."
  type        = string

  validation {
    condition     = can(regex("^svp-tfstate-[0-9]{12}-[a-z]{2}(-[a-z]+)+-[0-9]$", var.state_bucket))
    error_message = "state_bucket must be svp-tfstate-<12-digit account>-<region>."
  }
}

variable "state_kms_key_arn" {
  description = "ARN of the KMS key of the state, arn:aws:kms:<region>:<account>:key/<key-id> (state_kms_key_arn of the account-baseline module). IAM matches a key by its key ARN only, never by an alias ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:[a-z]{2}(-[a-z]+)+-[0-9]:[0-9]{12}:key/[0-9a-f-]+$", var.state_kms_key_arn))
    error_message = "state_kms_key_arn must be the key ARN arn:aws:kms:<region>:<account>:key/<key-id>, not an alias ARN."
  }
}
