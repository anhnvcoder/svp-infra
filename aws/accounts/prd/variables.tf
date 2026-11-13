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
  description = "Name of the hosted zone of prd, aws.<domain> (no trailing dot): the root zone of the lab, delegated by the NS records aws at the DNS of the parent domain. Set it in an uncommitted *.auto.tfvars or TF_VAR_zone_name."
  type        = string
}

variable "delegated_subdomains" {
  description = "Zones of other accounts delegated from the zone of prd: zone name to its four name servers. It holds stg.aws.<domain> mapped to the name_servers output of aws/accounts/stg, so new name servers of the stg zone need an apply of this root. Only prd declares it: stg delegates no zone. Set it in the uncommitted prd.auto.tfvars."
  type        = map(list(string))
  default     = {}
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

variable "dnssec_signing" {
  description = "Whether the zone of prd is DNSSEC signed. Set it to false (terraform apply -var dnssec_signing=false) only after the DS record aws at the parent domain's DNS is gone and its TTL has passed: the steps of the account-baseline README."
  type        = bool
  default     = true
}

variable "alarm_email" {
  description = "Address subscribed to the topic svp-prd-dns-alarms of the DNSSEC alarms (us-east-1). Personal data of a public repository: set it in the uncommitted prd.auto.tfvars or TF_VAR_alarm_email."
  type        = string
  sensitive   = true
}

variable "platform_admin_group_id" {
  description = "Id of the IAM Identity Center group svp-platform-admins (output platform_admin_group_id of aws/org): the ADMIN role of the Grafana workspace. Set it in the uncommitted <env>.auto.tfvars or TF_VAR_platform_admin_group_id."
  type        = string
}

variable "platform_viewer_group_id" {
  description = "Id of the IAM Identity Center group svp-platform-viewers (output platform_viewer_group_id of aws/org): the VIEWER role of the Grafana workspace. Set it in the uncommitted <env>.auto.tfvars or TF_VAR_platform_viewer_group_id."
  type        = string
}
