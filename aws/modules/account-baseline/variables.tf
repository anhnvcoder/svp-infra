variable "env" {
  description = "Environment the account runs (stg, prd): names the budget svp-<env>-monthly and appears in the comment of the hosted zone."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.env))
    error_message = "env must be 2 to 10 lowercase letters and digits, starting with a letter, e.g. stg."
  }
}

variable "account_id" {
  description = "The AWS account of the baseline (12 digits): part of the state bucket name and of the key policy. The root passes its own account_id, which never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Region of the state bucket and its KMS key, part of the bucket name; the root passes the region of its provider."
  type        = string

  validation {
    # svp-tfstate-<12 digits>-<region> stays within the 63 characters of a bucket name.
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.region)) && length(var.region) <= 14
    error_message = "region must be an AWS region name of at most 14 characters, e.g. ap-southeast-1."
  }
}

variable "zone_name" {
  description = "Name of the environment's hosted zone, e.g. aws.svp.example or stg.aws.svp.example. The zone above it delegates it with NS records to the name_servers output."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.zone_name))
    error_message = "zone_name must be a lowercase DNS name without a trailing dot, e.g. aws.svp.example."
  }
}

variable "delegated_subdomains" {
  description = "Child zones of other accounts to delegate from this zone: zone name (ending in .<zone_name>) to its four name servers, the name_servers output of the child's baseline. Each entry becomes an NS record in this zone."
  type        = map(list(string))
  default     = {}

  validation {
    condition = alltrue([for name, servers in var.delegated_subdomains :
      endswith(name, ".${var.zone_name}") && length(servers) == 4 && length(distinct(servers)) == 4
    ])
    error_message = "Each key of delegated_subdomains must end in \".\" followed by zone_name, and each value must hold exactly four distinct name servers."
  }
}

variable "budget_limit_usd" {
  description = "Monthly cost budget of the account, in US dollars. Alerts go out at 50, 80 and 100 percent of actual cost and at 100 percent of forecast cost."
  type        = number

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be a positive amount."
  }
}

variable "budget_emails" {
  description = "Addresses that receive the budget alerts. Personal data of a public repository: the root reads them from an uncommitted *.auto.tfvars or TF_VAR_budget_emails."
  type        = list(string)
  sensitive   = true

  validation {
    condition     = length(var.budget_emails) > 0 && alltrue([for e in var.budget_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e))])
    error_message = "budget_emails must hold at least one email address."
  }
}
