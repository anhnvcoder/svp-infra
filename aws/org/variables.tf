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
  description = "Root email of each member account: stg, prd, log-archive, security. Each must be an address no other AWS account uses, a closed or suspended one included. Personal data of a public repository: set it in the uncommitted org.auto.tfvars."
  type        = map(string)
  sensitive   = true

  validation {
    condition     = toset(keys(var.account_emails)) == toset(["stg", "prd", "log-archive", "security"]) && alltrue([for e in values(var.account_emails) : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e))])
    error_message = "account_emails must hold exactly the keys stg, prd, log-archive and security, each an email address."
  }

  validation {
    condition     = length(distinct([for e in values(var.account_emails) : lower(e)])) == length(var.account_emails)
    error_message = "account_emails must give each account its own address."
  }
}

variable "sso_user_name" {
  description = "User name of the learner in IAM Identity Center (top right of the AWS access portal), given the permission sets of identity-center.tf. Set it in the uncommitted org.auto.tfvars."
  type        = string

  validation {
    condition     = length(trimspace(var.sso_user_name)) > 0
    error_message = "sso_user_name must not be empty."
  }
}

variable "security_contact" {
  description = "Alternate contact of type SECURITY of the management account and every member account: who AWS writes to about security issues. Personal data of a public repository: set it in the uncommitted org.auto.tfvars."
  type = object({
    name          = string
    title         = string
    email_address = string
    phone_number  = string
  })
  sensitive = true

  validation {
    condition     = length(trimspace(var.security_contact.name)) > 0 && length(trimspace(var.security_contact.title)) > 0
    error_message = "security_contact needs a name and a title."
  }

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.security_contact.email_address))
    error_message = "security_contact.email_address must be an email address."
  }

  # The pattern of the Account Management API for PhoneNumber.
  validation {
    condition     = can(regex("^[\\s0-9()+-]+$", var.security_contact.phone_number))
    error_message = "security_contact.phone_number may hold only digits, spaces, parentheses, + and -."
  }
}
