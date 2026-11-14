variable "kms_key_arn" {
  description = "ARN of the customer managed KMS key that encrypts every vault of the module and the recovery points AWS Backup stores or copies into them. The key belongs to the calling root, which keeps its lifecycle and key policy."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:[a-z]{2}(-[a-z]+)+-[0-9]+:[0-9]{12}:key/[0-9a-f-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a key ARN (arn:aws:kms:<region>:<account>:key/<id>), not an alias."
  }
}

variable "vaults" {
  description = "Vaults to make, by name. lock: governance-mode vault lock, retention in days every recovery point of the vault must keep (null: no lock). copy_from_account_ids: 12-digit ids of the accounts allowed backup:CopyIntoBackupVault (empty: no vault access policy)."
  type = map(object({
    lock = optional(object({
      min_retention_days = number
      max_retention_days = number
    }))
    copy_from_account_ids = optional(list(string), [])
  }))

  validation {
    condition     = length(var.vaults) > 0
    error_message = "vaults must name at least one vault."
  }

  validation {
    # The name rule of the AWS Backup API.
    condition     = alltrue([for name in keys(var.vaults) : can(regex("^[a-zA-Z0-9_-]{2,50}$", name))])
    error_message = "Every vault name must be 2 to 50 letters, digits, hyphens and underscores."
  }

  validation {
    condition = alltrue([for v in values(var.vaults) :
      alltrue([for a in v.copy_from_account_ids : can(regex("^[0-9]{12}$", a))]) &&
      length(distinct(v.copy_from_account_ids)) == length(v.copy_from_account_ids)
    ])
    error_message = "copy_from_account_ids must hold 12-digit account ids, without repeats."
  }

  validation {
    # AWS Backup accepts a vault lock retention of 1 to 36500 days (PutBackupVaultLockConfiguration API reference).
    condition = alltrue([for v in values(var.vaults) : v.lock == null ? true : (
      v.lock.min_retention_days == null || v.lock.max_retention_days == null ? false : (
        floor(v.lock.min_retention_days) == v.lock.min_retention_days &&
        floor(v.lock.max_retention_days) == v.lock.max_retention_days &&
        v.lock.min_retention_days >= 1 &&
        v.lock.min_retention_days <= v.lock.max_retention_days &&
        v.lock.max_retention_days <= 36500
      )
    )])
    error_message = "A lock must give whole min_retention_days and max_retention_days, with 1 <= min_retention_days <= max_retention_days <= 36500."
  }
}
