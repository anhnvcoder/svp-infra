variable "account_id" {
  description = "The management account of the organization (12 digits): the credentials of AWS_PROFILE=anhnv-sso, which assume the role of the member accounts, and the first of the accounts this root changes. Set it with TF_VAR_account_id from SVP_AWS_MGMT_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "log_archive_account_id" {
  description = "The account svp-log-archive (12 digits): gets the baseline, and holds the Config bucket and the KMS key every delivery channel uses. Set it with TF_VAR_log_archive_account_id from SVP_AWS_LOG_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.log_archive_account_id))
    error_message = "log_archive_account_id must be the 12 digits of an AWS account id."
  }
}

variable "backup_account_id" {
  description = "The account svp-backup (12 digits): gets the baseline. Set it with TF_VAR_backup_account_id from SVP_AWS_BACKUP_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.backup_account_id))
    error_message = "backup_account_id must be the 12 digits of an AWS account id."
  }
}

variable "security_account_id" {
  description = "The account svp-security (12 digits): gets the baseline, and holds the bus svp-security-events every forwarding rule targets. Set it with TF_VAR_security_account_id from SVP_AWS_SECURITY_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.security_account_id))
    error_message = "security_account_id must be the 12 digits of an AWS account id."
  }
}

variable "stg_account_id" {
  description = "The account svp-stg (12 digits): gets the baseline and the EBS key. Set it with TF_VAR_stg_account_id from SVP_AWS_STG_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.stg_account_id))
    error_message = "stg_account_id must be the 12 digits of an AWS account id."
  }
}

variable "prd_account_id" {
  description = "The account svp-prd (12 digits): gets the baseline and the EBS key. Set it with TF_VAR_prd_account_id from SVP_AWS_PRD_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.prd_account_id))
    error_message = "prd_account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Home region of the organization: the provider region of every account, the Config bucket, the log archive key, the security event bus and the EBS keys."
  type        = string
  default     = "ap-southeast-1"
}

variable "sso_region" {
  description = "Region of the organization's IAM Identity Center instance, the same value as sso_region of aws/org: the only region where CloudTrail records permission set changes. Set it in the uncommitted baseline.auto.tfvars."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.sso_region))
    error_message = "sso_region must be an AWS region name, e.g. us-east-1."
  }
}
