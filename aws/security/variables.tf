variable "account_id" {
  description = "The management account of the organization (12 digits): the credentials of AWS_PROFILE=anhnv-sso, which assume the role of the member accounts. Set it with TF_VAR_account_id from SVP_AWS_MGMT_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "security_account_id" {
  description = "The account svp-security (12 digits), delegated administrator of the detection services and the only member account this root changes. Set it with TF_VAR_security_account_id from SVP_AWS_SECURITY_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.security_account_id))
    error_message = "security_account_id must be the 12 digits of an AWS account id."
  }
}

variable "log_archive_account_id" {
  description = "The account svp-log-archive (12 digits), read only: its GuardDuty bucket and KMS key receive the findings. Set it with TF_VAR_log_archive_account_id from SVP_AWS_LOG_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.log_archive_account_id))
    error_message = "log_archive_account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Home region of the organization: the Security Hub aggregation region, the security event bus and the alert topic."
  type        = string
  default     = "ap-southeast-1"
}

variable "security_alert_email" {
  description = "Email address of the topic svp-security-alarms; SNS sends it a confirmation link and delivers nothing until the link is opened. Personal data of a public repository: set it in the uncommitted security.auto.tfvars."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.security_alert_email))
    error_message = "security_alert_email must be an email address."
  }
}
