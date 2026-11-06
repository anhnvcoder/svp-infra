variable "account_id" {
  description = "The AWS account this root may change (12 digits). Set it with TF_VAR_account_id from the account variable of the environment after checking the account with aws sts get-caller-identity; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Region of the state bucket, its KMS key and the API calls of this root."
  type        = string
  default     = "ap-southeast-1"
}

variable "zone_name" {
  description = "Name of the hosted zone of stg, stg.aws.<domain> (no trailing dot). The zone of prd delegates it with NS records (delegated_subdomains of aws/accounts/prd). Set it in an uncommitted *.auto.tfvars or TF_VAR_zone_name."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly cost budget of the account, in US dollars."
  type        = number
  default     = 20
}

variable "budget_emails" {
  description = "Addresses that receive the budget alerts. Personal data of a public repository: set it in an uncommitted *.auto.tfvars or TF_VAR_budget_emails."
  type        = list(string)
  sensitive   = true
}
