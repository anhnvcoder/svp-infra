variable "account_id" {
  description = "The management account of the organization (12 digits): owner of the organization trail svp-audit whose logs land here. Set it with TF_VAR_account_id from SVP_AWS_MGMT_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "log_archive_account_id" {
  description = "The account svp-log-archive (12 digits), the only account this root may change. Set it with TF_VAR_log_archive_account_id from SVP_AWS_LOG_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.log_archive_account_id))
    error_message = "log_archive_account_id must be the 12 digits of an AWS account id."
  }
}

variable "security_account_id" {
  description = "The account svp-security (12 digits), whose GuardDuty detectors export findings here. Set it with TF_VAR_security_account_id from SVP_AWS_SECURITY_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.security_account_id))
    error_message = "security_account_id must be the 12 digits of an AWS account id."
  }
}

variable "stg_account_id" {
  description = "The account svp-stg (12 digits), whose flow logs and WAF logs are kept for a shorter time. Set it with TF_VAR_stg_account_id from SVP_AWS_STG_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.stg_account_id))
    error_message = "stg_account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Home region of the organization: every log bucket and the first KMS key, except the WAF log bucket and its key in us-east-1."
  type        = string
  default     = "ap-southeast-1"
}
