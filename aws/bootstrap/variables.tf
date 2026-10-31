variable "account_id" {
  description = "The AWS account this root may change (12 digits). Set it with TF_VAR_account_id after reading the account from aws sts get-caller-identity; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Region of the state bucket and of the API calls of this root."
  type        = string
  default     = "ap-southeast-1"
}

variable "budget_limit_usd" {
  description = "Monthly cost budget of the account, in US dollars. Alerts go out at 50, 80 and 100 percent of actual cost and at 100 percent of forecast cost."
  type        = number
  default     = 20

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be a positive amount."
  }
}

variable "budget_emails" {
  description = "Addresses that receive the budget alerts. Personal data of a public repository: set it in an uncommitted *.auto.tfvars or TF_VAR_budget_emails."
  type        = list(string)
  sensitive   = true

  validation {
    condition     = length(var.budget_emails) > 0 && alltrue([for e in var.budget_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e))])
    error_message = "budget_emails must hold at least one email address."
  }
}

variable "zone_name" {
  description = "The lab subdomain whose hosted zone this root creates, aws.<domain>. It is delegated by NS records at the DNS that serves the parent domain. Set it in an uncommitted *.auto.tfvars or TF_VAR_zone_name."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.zone_name))
    error_message = "zone_name must be a lowercase DNS name without a trailing dot, e.g. aws.svp.example."
  }
}
