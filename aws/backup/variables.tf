variable "account_id" {
  description = "The management account of the organization (12 digits): the credentials of AWS_PROFILE=anhnv-sso, which assume the role of the backup account. Set it with TF_VAR_account_id from SVP_AWS_MGMT_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12 digits of an AWS account id."
  }
}

variable "backup_account_id" {
  description = "The account svp-backup (12 digits), the only account this root may change. Set it with TF_VAR_backup_account_id from SVP_AWS_BACKUP_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.backup_account_id))
    error_message = "backup_account_id must be the 12 digits of an AWS account id."
  }
}

variable "stg_account_id" {
  description = "The account svp-stg (12 digits), the only account allowed to copy into the vault svp-stg-copy. Set it with TF_VAR_stg_account_id from SVP_AWS_STG_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.stg_account_id))
    error_message = "stg_account_id must be the 12 digits of an AWS account id."
  }
}

variable "prd_account_id" {
  description = "The account svp-prd (12 digits), the only account allowed to copy into the vault svp-prd-copy. Set it with TF_VAR_prd_account_id from SVP_AWS_PRD_ACCOUNT_ID; it never goes into a committed file."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.prd_account_id))
    error_message = "prd_account_id must be the 12 digits of an AWS account id."
  }
}

variable "region" {
  description = "Home region of the organization: the key and both copy vaults, the region of the env vaults and of the copy actions of the backup policies."
  type        = string
  default     = "ap-southeast-1"
}
