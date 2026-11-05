variable "account_id" {
  description = "The management account of the organization (12 digits), the only account this root may change. Set it with TF_VAR_account_id from SVP_AWS_MGMT_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Home region of the organization trail, its KMS key and its buckets."
  type        = string
  default     = "ap-southeast-1"
}

variable "sso_region" {
  description = "Region of the organization's IAM Identity Center instance (sso_region of the learner's SSO profile). Set it in the uncommitted org.auto.tfvars."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.sso_region))
    error_message = "sso_region must be an AWS region name, e.g. us-east-1."
  }
}

variable "account_emails" {
  description = "Root email of each member account, by env (stg, prd). Each must be an address no other AWS account uses, a closed or suspended one included. Personal data of a public repository: set it in the uncommitted org.auto.tfvars."
  type        = map(string)
  sensitive   = true

  validation {
    condition     = toset(keys(var.account_emails)) == toset(["stg", "prd"]) && alltrue([for e in values(var.account_emails) : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e))])
    error_message = "account_emails must hold exactly the keys stg and prd, each an email address."
  }

  validation {
    condition     = length(distinct([for e in values(var.account_emails) : lower(e)])) == length(var.account_emails)
    error_message = "account_emails must give each account its own address."
  }
}

variable "sso_user_name" {
  description = "User name of the learner in IAM Identity Center (top right of the AWS access portal), given SvpAdmin in both member accounts. Set it in the uncommitted org.auto.tfvars."
  type        = string

  validation {
    condition     = length(trimspace(var.sso_user_name)) > 0
    error_message = "sso_user_name must not be empty."
  }
}
